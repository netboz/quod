using System.Numerics;

namespace Quod.Client;

// One pie from a subject's authored menu recipe. Labels, wedge positions, the
// back direction, availability and confirmation all arrive from the ontology;
// this decodes them and maps a pointer direction onto those fixed wedges.
public sealed record MenuTarget(Term Subject, Term Choice, string Label = "");

public sealed record MenuNode(Term Id, string Label, string Help, bool Enabled, int Slot, int Wedges, int Back,
    MenuTarget? Target, bool Confirm, MenuNode[] Children, string? Image = null, long Transfer = 0, long Pixels = 0)
{
    public bool Leaf => Target != null;
    // Everything a presentation depends on; an equal signature is the same pie.
    public string Signature => string.Join("|", Id, Label, Help, Enabled, Slot, Wedges, Back, Confirm, Target?.Subject, Target?.Choice, Image, Transfer, Pixels)
        + "[" + string.Join(",", Children.Select(c => c.Signature)) + "]";
    public MenuNode? At(int slot) => Children.FirstOrDefault(c => c.Slot == slot);
    public string Initials => InitialsOf(Label);
    // The fallback mark of a command without an authored icon: the first letters of its label.
    public static string InitialsOf(string label) => string.Concat(label.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2)
        .Select(w => char.ToUpperInvariant(w[0])));

    // The read answers menu(Tree), or none when the subject offers no menu.
    public static MenuNode? Decode(Term view)
    {
        view.Ground();
        if (view.Kind == "atom" && view.Name == "none") return null;
        var ids = new HashSet<string>();
        MenuNode Read(Term term, int wedges)
        {
            var a = term.Require("component", 4);
            if (!ids.Add(a[0].ToString()) || a[1].Kind != "atom" || a[1].Name is not ("menu" or "menu_item"))
                throw new FormatException("A pie holds only menus and menu items, each once.");
            var p = a[2].Items.Select(x => x.Require("property", 2)).ToDictionary(x => x[0].Name, x => x[1]);
            string label = p["label"].TextValue, help = p["help"].TextValue;
            if (label.Length == 0) throw new FormatException("Unlabelled wedge.");
            var image = Component.ImageAsset(p.GetValueOrDefault("image"));
            bool Flag(string key) => p[key].Kind == "atom" && p[key].Name is "true" or "false"
                ? p[key].Name == "true" : throw new FormatException("Invalid menu flag.");
            int slot = p["slot"].Kind == "atom" && p["slot"].Name == "auto" ? 0 : (int)p["slot"].Integer;
            if (a[1].Name == "menu_item") {
                if (a[3].Items.Length != 0 || slot < 1 || slot > wedges) throw new FormatException("Invalid menu item.");
                var t = p["target"].Require("choice", 2);
                if (t[0].Name is not ("entity_ref" or "class_ref" or "ontology_ref")) throw new FormatException("Unsupported menu subject.");
                t[1].Require("eidolon", 3)[2].Require("recipe", 3);
                return new(a[0], label, help, Flag("enabled"), slot, wedges, 0, new(t[0], t[1], label), Flag("confirm"), [], image.File, image.Transfer, image.Pixels);
            }
            if (wedges != int.MaxValue && (slot < 1 || slot > wedges)) throw new FormatException("Invalid nested menu slot.");
            int own = (int)p["wedges"].Integer;
            int back = p["back"].Kind == "atom" && p["back"].Name == "none" ? 0 : (int)p["back"].Integer;
            if (own < 1 || back < 0 || back > own) throw new FormatException("Invalid menu layout.");
            var children = a[3].Items.Select(c => Read(c, own)).ToArray();
            var slots = children.Select(c => c.Slot).ToArray();
            if (slots.Distinct().Count() != slots.Length || slots.Contains(back)) throw new FormatException("Overlapping wedges.");
            return new(a[0], label, help, Flag("enabled"), slot, own, back, null, false, children, image.File, image.Transfer, image.Pixels);
        }
        var root = Read(view.Require("menu", 1)[0], int.MaxValue);
        if (root.Leaf || root.Back != 0) throw new FormatException("A pie starts at a menu.");
        return root;
    }

    // Direction, not distance, selects. Slot 1 points forward (-Y on the pad
    // and up on screen), then clockwise. Inside the dead zone the answer is 0.
    public static int Direction(Vector2 axes, float threshold, int wedges)
    {
        if (axes.Length() < threshold || wedges < 1) return 0;
        double turn = Math.PI * 2, angle = (Math.Atan2(axes.X, -axes.Y) + turn + Math.PI / wedges) % turn;
        return (int)Math.Floor(angle / (turn / wedges)) % wedges + 1;
    }
    public static Vector2 Toward(int slot, int wedges)
    { double angle = Math.PI * 2 * (slot - 1) / wedges; return new((float)Math.Sin(angle), -(float)Math.Cos(angle)); }
}

public enum PieOutcome { Open, Selected, Cancelled }

// Navigation state for one open pie. Callers supply the pointer direction
// relative to the current level's centre (pad axes, or a cursor/ray offset
// divided by the pie radius). Marking opens a sub-pie when the pointer rests
// on it; turbo release and clicks commit the hovered wedge.
public sealed class PieNavigator(MenuNode root, float threshold, double markingDwell)
{
    readonly List<MenuNode> path = [root];
    double restingSince;
    Vector2 rest;
    // The direction held when a level changed. A new level starts from the
    // centre: the same held direction points nothing until it leaves it, as a
    // held control needs neutral before a new gesture.
    Vector2? rearm;
    public MenuNode Root => root;
    public MenuNode Level => path[^1];
    public IReadOnlyList<MenuNode> Path => path;
    public int Hovered { get; private set; }
    public Term? Armed { get; private set; }
    public MenuTarget? Selection { get; private set; }
    public bool HoveringBack => Hovered != 0 && Hovered == Level.Back;
    public MenuNode? HoveredItem => HoveringBack ? null : Level.At(Hovered);
    // What the centre says: the pointed wedge's label, or the level's name
    // when nothing is pointed; beneath it, the one thing to know before pressing.
    public string Title => HoveringBack ? "Back" : HoveredItem?.Label ?? Level.Label;
    public string Note => HoveringBack ? path[^2].Label
        : HoveredItem is not { } item ? ""
        : !item.Enabled ? item.Help
        : Armed?.ToString() == item.Id.ToString() ? "Press again" : "";

    // Returns whether anything visible changed.
    public bool Move(Vector2 direction, double now)
    {
        if (rearm is Vector2 held) { if (Vector2.Distance(direction, held) <= threshold) direction = Vector2.Zero; else rearm = null; }
        int next = MenuNode.Direction(direction, threshold, Level.Wedges);
        if (next != 0 && next != Level.Back && Level.At(next) == null) next = 0;
        bool changed = next != Hovered;
        if (changed) { Hovered = next; if (Armed != null && HoveredItem?.Id.ToString() != Armed.ToString()) Armed = null; }
        if (changed || Vector2.Distance(direction, rest) > threshold / 2) { rest = direction; restingSince = now; return changed; }
        if (now - restingSince < markingDwell) return false;
        restingSince = double.MaxValue;
        if (HoveringBack) return Back();
        if (HoveredItem is { Leaf: false, Enabled: true } menu) { Enter(menu); return true; }
        return false;
    }
    public bool Choose(int slot) { if (slot != Level.Back && Level.At(slot) == null) return false; Hovered = slot; return true; }
    public bool Back()
    {
        if (path.Count == 1) return false;
        path.RemoveAt(path.Count - 1); Changed(); return true;
    }
    void Enter(MenuNode menu) { path.Add(menu); Changed(); }
    void Changed() { Hovered = 0; Armed = null; restingSince = double.MaxValue; rearm = rest; }

    // A confirmed item needs a second commit on the same wedge; the centre
    // cancels; a disabled wedge stays open showing its reason.
    public PieOutcome Commit()
    {
        if (Hovered == 0) return PieOutcome.Cancelled;
        if (HoveringBack) { Back(); return PieOutcome.Open; }
        var item = HoveredItem!;
        if (!item.Enabled) return PieOutcome.Open;
        if (!item.Leaf) { Enter(item); return PieOutcome.Open; }
        if (item.Confirm && Armed?.ToString() != item.Id.ToString()) { Armed = item.Id; return PieOutcome.Open; }
        Selection = item.Target; return PieOutcome.Selected;
    }
}

// The only placement numbers the client introduces (decision 4, 2026-11-05):
// a first Vive profile, to be measured on the headset. Not domain policy.
// The working panel takes the pie's angle below eye level (Yan, 2026-11-13).
// The HUD strip numbers (25° below eye level, following after a 35° head turn)
// were chosen by Yan on 2026-11-06 for the same first profile.
public sealed record DeviceProfile(float ReadingDistance, float BelowEyeDegrees, float HudBelowEyeDegrees, float HudFollowDegrees)
{
    public static readonly DeviceProfile Vive = new(1.5f, 15f, 25f, 35f);
    // Tag-along: the strip keeps its heading until the head has turned past
    // the threshold, then takes the head's heading. It never jitters with it.
    public float? FollowYaw(float? current, float head)
    {
        if (current is not float yaw) return head;
        float turned = Math.Abs(((head - yaw) % 360 + 540) % 360 - 180);
        return turned > HudFollowDegrees ? head : yaw;
    }
}
