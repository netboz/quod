using System.Text;

namespace Quod.Client;

// Rain, one texture of a surface: a text whose letters stand still in columns
// while light falls down each column. The text is carried in the mark, or named
// as the whole source of an exact ontology that the client reads itself.
public sealed record SceneRain(string? Text, Term? Source, Length Height)
{
    public static SceneRain Decode(Term text, Term glyph)
    {
        var height = Length.Decode(glyph.Require("glyph", 1)[0], false);
        if (text.Name == "text") {
            var written = text.Require("text", 1)[0];
            if (written.Kind != "binary" || written.Bytes.Length == 0) throw new FormatException("Rain needs a text.");
            return new(written.TextValue, null, height);
        }
        var source = text.Require("source", 1)[0]; var named = source.Require("ontology_ref", 2);
        if (named[0].Kind != "binary" || named[0].Bytes.Length == 0 || named[1].Kind != "binary" || named[1].Bytes.Length != 32)
            throw new FormatException("Rain names no exact ontology.");
        _ = named[0].TextValue;
        return new(null, source, height);
    }
    // One drawing per text: a named source by its exact identity, else the text.
    public string Key => Source?.ToString() ?? Term.Text(Text!).ToString();
}

// The cells of a rain text: white space is dropped, so no cell is empty. Each
// distinct letter is drawn once; each cell holds the index of its letter.
public sealed record RainCells(string[] Letters, int[] Cells)
{
    public static RainCells Of(string text)
    {
        var letters = new List<string>(); var index = new Dictionary<string, int>(); var cells = new List<int>();
        foreach (var rune in text.EnumerateRunes()) {
            if (Rune.IsWhiteSpace(rune) || Rune.IsControl(rune)) continue;
            string letter = rune.ToString();
            if (!index.TryGetValue(letter, out int at)) { at = letters.Count; index.Add(letter, at); letters.Add(letter); }
            cells.Add(at);
        }
        if (cells.Count == 0) throw new FormatException("A rain text needs at least one letter that is not white space.");
        return new([.. letters], [.. cells]);
    }
}
