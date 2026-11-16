using Godot;
using Quod.Client;

// The client's drawing of rain, the same for every user of it: one shader, one
// letter atlas per set of letters, one cell texture per text. A named source is
// read once per reader, with the Source panel's read. Until its text arrives,
// or when the read is refused, the surface shows no rain; a refusal goes to the
// trace.
public sealed class RainMaterials(Func<Term,CancellationToken,Task<string>> read,Action drawn) : IDisposable
{
    // The font's line, ascent plus descent at the distance-field size, is one cell.
    const int FieldSize = 48, FieldRange = 24, Slot = 64;
    static readonly Shader Opaque = GD.Load<Shader>("res://rain.gdshader");
    static Shader? translucent;
    static FontFile? font;
    sealed class Text
    {
        public Term? Source;
        public ImageTexture? Cells, Letters;
        public string LetterSet = "";
        public int Count;
        public readonly List<WeakReference<ShaderMaterial>> Users = [];
    }
    readonly Dictionary<string,Text> texts = [];
    readonly Dictionary<string,ImageTexture> atlases = [];
    readonly CancellationTokenSource lifetime = new();
    public int SourceReads { get; private set; }
    public ShaderMaterial Material(SceneSurface surface, Vector3 size)
    {
        var rain = surface.Rain!;
        var material = new ShaderMaterial { Shader = surface.Opacity < 1000 ? Translucent : Opaque };
        var colour = new Color(surface.Colour);
        material.SetShaderParameter("box_size", size);
        material.SetShaderParameter("cell_height", rain.Height.RenderMetres());
        material.SetShaderParameter("lit_colour", new Vector3(colour.R, colour.G, colour.B));
        material.SetShaderParameter("brightness", surface.Emission / 1000f);
        material.SetShaderParameter("opacity", surface.Opacity / 1000f);
        material.SetShaderParameter("letter_slot", Slot);
        material.SetShaderParameter("letter_range", FieldRange / (float)Slot);
        material.SetShaderParameter("rollover", ProjectSettings.GetSetting("rendering/limits/time/time_rollover_secs").AsSingle());
        if (!texts.TryGetValue(rain.Key, out var text)) {
            texts.Add(rain.Key, text = new() { Source = rain.Source });
            if (rain.Source != null) Read(rain.Key, text);
            else Build(text, rain.Text!);
        }
        text.Users.RemoveAll(user => !user.TryGetTarget(out _));
        text.Users.Add(new(material));
        if (text.Count > 0) Bind(material, text);
        return material;
    }
    // A carried text no shown mark uses any more is let go; named sources stay
    // read for this reader's lifetime.
    public void Retain(IEnumerable<string> used)
    {
        var keep = used.ToHashSet();
        foreach (var key in texts.Where(t => t.Value.Source == null && !keep.Contains(t.Key)).Select(t => t.Key).ToArray()) texts.Remove(key);
        var sets = texts.Values.Select(t => t.LetterSet).ToHashSet();
        foreach (var set in atlases.Keys.Where(set => !sets.Contains(set)).ToArray()) atlases.Remove(set);
    }
    async void Read(string key, Text text)
    {
        SourceReads++;
        var timer = System.Diagnostics.Stopwatch.StartNew();
        try {
            string source = await read(text.Source!, lifetime.Token);
            if (!texts.TryGetValue(key, out var current) || current != text) return;
            Build(text, source);
            Quod.Client.Trace.Line("rain", $"source={key} bytes={System.Text.Encoding.UTF8.GetByteCount(source)} cells={text.Count} ms={timer.ElapsedMilliseconds}");
        } catch (OperationCanceledException) when (lifetime.IsCancellationRequested) {
        } catch (Exception error) {
            Quod.Client.Trace.Line("rain", $"source={key} refused={error.Message}");
        }
    }
    void Build(Text text, string written)
    {
        try {
            var cells = RainCells.Of(written);
            // Without a rendering device (headless) nothing is drawn; the number
            // then only shapes the textures.
            long limit = (long?)RenderingServer.GetRenderingDevice()?.LimitGet(RenderingDevice.Limit.MaxTextureSize2D) ?? 16384;
            int across = (int)Math.Min(cells.Cells.Length, limit), rows = (cells.Cells.Length + across - 1) / across;
            if (rows > limit || cells.Letters.Length > 65536)
                throw new FormatException($"Rain of {cells.Cells.Length} letters ({cells.Letters.Length} distinct) is larger than this device's largest texture holds.");
            int wide = cells.Letters.Length > 256 ? 2 : 1; var bytes = new byte[(long)across * rows * wide];
            for (int i = 0; i < cells.Cells.Length; i++) { bytes[i * wide] = (byte)cells.Cells[i]; if (wide == 2) bytes[i * 2 + 1] = (byte)(cells.Cells[i] >> 8); }
            text.Cells = ImageTexture.CreateFromImage(Image.CreateFromData(across, rows, false, wide == 2 ? Image.Format.Rg8 : Image.Format.R8, bytes));
            text.LetterSet = string.Join("\n", cells.Letters); text.Letters = Atlas(text.LetterSet, cells.Letters, limit); text.Count = cells.Cells.Length;
            bool shown = false;
            foreach (var user in text.Users) if (user.TryGetTarget(out var material)) { Bind(material, text); shown = true; }
            if (shown) drawn();
        } catch (Exception error) {
            Quod.Client.Trace.Line("rain", $"text refused={error.Message}");
        }
    }
    static void Bind(ShaderMaterial material, Text text)
    {
        material.SetShaderParameter("letters", text.Letters!);
        material.SetShaderParameter("cells", text.Cells!);
        material.SetShaderParameter("cell_count", text.Count);
    }
    // Each letter once, as the engine renders it: a multichannel signed distance
    // field, its true distance in alpha, centred on its advance in its slot.
    ImageTexture Atlas(string key, string[] letters, long limit)
    {
        if (atlases.TryGetValue(key, out var built)) return built;
        var field = Font; var size = new Vector2I(FieldSize, 0);
        int across = (int)Math.Ceiling(Math.Sqrt(letters.Length)), down = (letters.Length + across - 1) / across;
        if ((long)across * Slot > limit) throw new FormatException($"Rain of {letters.Length} distinct letters is larger than this device's largest texture holds.");
        var atlas = Image.CreateEmpty(across * Slot, down * Slot, false, Image.Format.Rgba8);
        var pages = new Dictionary<int,Image>(); int missing = 0;
        float baseline = field.GetCacheAscent(0, FieldSize);
        for (int i = 0; i < letters.Length; i++) {
            int glyph = field.GetGlyphIndex(FieldSize, char.ConvertToUtf32(letters[i], 0), 0);
            if (glyph == 0) { missing++; continue; }
            field.RenderGlyph(0, size, glyph);
            var rect = field.GetGlyphUVRect(0, size, glyph); var offset = field.GetGlyphOffset(0, size, glyph);
            int page = field.GetGlyphTextureIdx(0, size, glyph);
            if (!pages.TryGetValue(page, out var image)) pages[page] = image = field.GetTextureImage(0, size, page);
            var slot = new Vector2I(i % across * Slot, i / across * Slot);
            var at = slot + new Vector2I((int)Math.Round((Slot - field.GetGlyphAdvance(0, FieldSize, glyph).X) / 2 + offset.X), (int)Math.Round(baseline + offset.Y));
            var source = new Rect2I((Vector2I)rect.Position, (Vector2I)rect.Size);
            // Clip to the slot so a tall letter's halo never reaches its neighbour.
            var target = new Rect2I(at, source.Size).Intersection(new Rect2I(slot, new(Slot, Slot)));
            if (target.HasArea()) atlas.BlitRect(image, new Rect2I(source.Position + target.Position - at, target.Size), target.Position);
        }
        if (missing > 0) Quod.Client.Trace.Line("rain", $"letters={letters.Length} missing_from_font={missing}");
        return atlases[key] = ImageTexture.CreateFromImage(atlas);
    }
    static FontFile Font
    {
        get {
            if (font != null) return font;
            font = (FontFile)GD.Load<FontFile>("res://assets/JetBrainsMonoNL-Bold.ttf").Duplicate();
            font.MultichannelSignedDistanceField = true; font.MsdfSize = FieldSize; font.MsdfPixelRange = FieldRange;
            return font;
        }
    }
    static Shader Translucent => translucent ??= new() { Code = "#define TRANSLUCENT\n" + Opaque.Code };
    public void Dispose() { lifetime.Cancel(); texts.Clear(); lifetime.Dispose(); }
}
