using System.Numerics;
using System.Text;

namespace Quod.Client;

public sealed record Component(Term Id, string Kind, Dictionary<string, Term> Properties, Component[] Children)
{
    public string Role => Id.ToString();
    // The server's schema digest uses this same separation. Appearance cannot
    // replace controls, fields, bindings or the baseline of a pending draft.
    public Term Semantic => Term.Call("component",Id,Term.Atom(Kind),
        Term.List(Properties.Where(p=>p.Key!="appearance").Select(p=>Term.Call("property",Term.Atom(p.Key),p.Value)).ToArray()),
        Term.List(Children.Select(c=>c.Semantic).ToArray()));
    public string Label => Properties["label"].Kind == "binary" ? Properties["label"].TextValue : Properties["label"].Name;
    public bool Flag(string name, bool fallback = false) => Properties.TryGetValue(name, out var value) ? value.Name == "true" : fallback;
    public string Family => FamilyOf(Kind);
    public static string FamilyOf(string kind) => kind switch {
        "form" or "container" or "panel" or "group" or "row" or "column" or "grid" or "scroll" or "tabs" or "menu" or "dialog" => "container",
        "text_box" or "text_area" => "text", "slider" or "rotary_knob" or "number_input" => "number",
        "checkbox" or "toggle" => "boolean", "selection" or "radio_group" or "selectable_list" or "table" => "choice",
        "label" or "status" or "help" or "error" or "separator" or "progress" => "display",
        "editor"=>"editor", "catalogue_selection"=>"catalogue", "bindings"=>"bindings",
        "button" => "button", "viewer_pose" => "view", _ => throw new FormatException("Unsupported GUI component: " + kind) };
    public IEnumerable<Component> Leaves => Family == "container" ? Children.SelectMany(c => c.Leaves) : [this];
    public bool Input => Family is "text" or "number" or "boolean" or "choice" or "view";
    public (BigInteger Min, BigInteger Max, BigInteger Step) Range
    {
        get { var a = Properties["range"].Require("range", 3); return (a[0].Integer, a[1].Integer, a[2].Integer); }
    }
    public (Term Value, string Label)[] Options => Properties["options"].Items.Select(row => {
        var args = row.Require("option", 2);
        string Text(Term t) => t.Kind == "binary" ? t.TextValue : t.Kind == "atom" ? t.Name : throw new FormatException("Invalid option label.");
        return (args[0], Kind == "table" ? string.Join(" · ", args[1].Items.Select(Text)) : Text(args[1]));
    }).ToArray();
    public static Component Decode(Term value)
    {
        value.Ground(); var ids = new HashSet<string>();
        Component Read(Term term) {
            var args = term.Require("component", 4);
            if (!ids.Add(args[0].ToString()) || args[1].Kind != "atom") throw new FormatException("Invalid or repeated control identity.");
            string kind = args[1].Name, family = FamilyOf(kind);
            var allowed = new HashSet<string>(["label", "help", "enabled"]);
            if (family == "container") allowed.UnionWith(["layout","appearance"]);
            if (family is "text" or "number" or "boolean" or "choice" or "view") allowed.UnionWith(["required", "readonly"]);
            if (family is "editor" or "catalogue")allowed.Add("readonly");
            if (family == "text") allowed.Add("max_bytes");
            if (family == "number") allowed.UnionWith(["range", "unit"]);
            if (family == "choice") allowed.Add("options");
            if (kind is "selectable_list" or "table") allowed.Add("multiple");
            if (kind == "table") allowed.Add("headings");
            if (kind == "grid") allowed.Add("columns");
            if (kind == "scroll") allowed.Add("visible_rows");
            if (kind == "progress") allowed.Add("percent");
            // A form's image is the icon of the operation it offers.
            if (kind is "button" or "form") allowed.Add("image");
            var props = new Dictionary<string, Term>();
            foreach (var p in args[2].Items) {
                var a = p.Require("property", 2);
                if (a[0].Kind != "atom" || !allowed.Contains(a[0].Name) || !props.TryAdd(a[0].Name, a[1]))
                    throw new FormatException("Unsupported or duplicate GUI property.");
                switch (a[0].Name) {
                    case "appearance": _=AppearanceTokens(a[1]); break;
                    case "enabled": case "readonly": case "required": case "multiple":
                        if (a[1].Kind != "atom" || a[1].Name is not ("true" or "false")) throw new FormatException("Invalid GUI flag."); break;
                    case "label": case "unit":
                        if (a[1].Kind is not ("binary" or "atom")) throw new FormatException("Invalid GUI label/unit."); break;
                    case "help": _ = a[1].TextValue; break;
                    case "layout": if (a[1].Name is not ("row" or "column" or "grid")) throw new FormatException("Unsupported layout."); break;
                    case "max_bytes": if (a[1].Integer < 0) throw new FormatException("Invalid text bound."); break;
                    case "columns": case "visible_rows": if (a[1].Integer <= 0) throw new FormatException("Invalid layout extent."); break;
                    case "percent": if (a[1].Integer < 0 || a[1].Integer > 100) throw new FormatException("Invalid progress."); break;
                    case "image":
                        _ = ImageAsset(a[1]);
                        break;
                }
            }
            if (!props.ContainsKey("label")) throw new FormatException("Missing GUI label.");
            var children = args[3].Items.Select(Read).ToArray();
            if (family != "container" && children.Length != 0) throw new FormatException("Leaf has children.");
            var result = new Component(args[0], kind, props, children);
            if (family == "number") { var (min, max, step) = result.Range;
                if (min > max || step <= 0) throw new FormatException("Invalid numeric range."); }
            if (family == "choice") {
                var options = result.Options;
                if (options.Length == 0 || options.Select(o => o.Value.ToString()).Distinct().Count() != options.Length)
                    throw new FormatException("Invalid choices.");
                if (kind == "table") {
                    int columns = props["headings"].Items.Length;
                    if (columns == 0 || props["options"].Items.Any(row => row.Args[1].Items.Length != columns)) throw new FormatException("Invalid table columns.");
                }
            }
            if (kind == "progress" && !props.ContainsKey("percent")) throw new FormatException("Missing progress.");
            return result;
        }
        return Read(value);
    }
    public static (string? File, long Transfer, long Pixels) ImageAsset(Term? value)
    {
        if (value == null || value.Kind == "atom" && value.Name == "none") return (null, 0, 0);
        var image = value.Require("image", 2);
        var asset = image[0].Require("asset", 2);
        string digest = asset[0].TextValue, extension = asset[1].TextValue switch {
            "image/png" => "png", "image/jpeg" => "jpg", _ => throw new FormatException("Unsupported image type.") };
        var resources = image[1].Require("resources", 2);
        long transfer = checked((long)resources[0].Integer), pixels = checked((long)resources[1].Integer);
        if (!System.Text.RegularExpressions.Regex.IsMatch(digest, "^[a-f0-9]{64}$") || transfer <= 0 || pixels <= 0)
            throw new FormatException("Invalid image admission.");
        return (digest + "." + extension, transfer, pixels);
    }
    public static Dictionary<string,Term> AppearanceTokens(Term value)
    {
        value.Ground();var tokens=new Dictionary<string,Term>();
        if(value.Kind=="atom"&&value.Name=="inherit")return tokens;
        var appearance=value.Require("appearance",2);
        if(appearance[0].Integer!=1)throw new FormatException("Unsupported GUI appearance version.");
        foreach(var token in appearance[1].Items) {
            var a=token.Require("token",2);string name=a[0].Name;
            if(a[0].Kind!="atom"||!tokens.TryAdd(name,a[1]))throw new FormatException("Duplicate GUI appearance token.");
            if(name is "panel" or "field" or "text" or "accent" or "edge" or "error" or "success") {
                if(a[1].Require("rgb",3).Any(n=>n.Integer<0||n.Integer>255))throw new FormatException("Invalid GUI colour.");
            } else if(name=="panel_opacity") {
                if(a[1].Integer<0||a[1].Integer>1000)throw new FormatException("Invalid panel opacity.");
            } else if(name is "spacing" or "padding" or "corner_radius") {
                if(a[1].Integer<0||a[1].Integer>int.MaxValue)throw new FormatException("Unrenderable GUI appearance extent.");
            } else throw new FormatException("Unsupported GUI appearance token: "+name);
        }
        return tokens;
    }
    public Term Draft(string text, bool initial = false)
    {
        switch (Family) {
            case "text":
                int bytes = Encoding.UTF8.GetByteCount(text);
                if (!initial && ((Flag("required") && bytes == 0) || (Properties.TryGetValue("max_bytes", out var max) && bytes > max.Integer)))
                    throw new FormatException("Text is required or exceeds its byte allowance.");
                return Term.Text(text);
            case "boolean":
                if (text is not ("true" or "false") || (!initial && Flag("required") && text != "true")) throw new FormatException("Confirm this field.");
                return Term.Atom(text);
            case "number":
                var value = Term.Parse(text); var integer = value.Integer; var (low, high, step) = Range;
                if (!initial && (integer < low || integer > high || (integer - low) % step != 0)) throw new FormatException("Value is outside the offered range/step.");
                return value;
            case "choice":
                var selected = Term.Parse(text); var choices = Flag("multiple") ? selected.Items : [selected];
                if ((!initial && Flag("required") && choices.Length == 0) || choices.Select(x => x.ToString()).Distinct().Count() != choices.Length ||
                    choices.Any(c => !Options.Any(o => o.Value.ToString() == c.ToString()))) throw new FormatException("Choose an offered value.");
                return selected;
            case "view":
                // Filled by this device, never typed: none, or where the eyes
                // are and the level direction they look along.
                var view = Term.Parse(text);
                if (view.Kind == "atom" && view.Name == "none") return view;
                var at = view.Require("view", 2);
                if (at[0].Require("transform", 6).Concat(at[1].Require("forward", 3)).Any(n => n.Kind != "number"))
                    throw new FormatException("Invalid viewer pose.");
                return view;
            default: throw new FormatException("Control is not an input.");
        }
    }
}

public sealed record Form(Component Tree, Term Submit, Dictionary<string, string> Defaults)
{
    public static Form Decode(Term tree, Term fields, Term control)
    {
        var component = Component.Decode(tree);
        if (component.Kind != "form" || !component.Leaves.Any(c => c.Kind == "button" && c.Role == control.ToString())) throw new FormatException("Missing submit control.");
        var inputs = component.Leaves.Where(c => c.Input).ToDictionary(c => c.Role);
        var values = new Dictionary<string, string>();
        foreach (var row in fields.Items) {
            var a = row.Require("field", 2); string role = a[0].ToString();
            if (!inputs.TryGetValue(role, out var field)) throw new FormatException("Unknown field identity.");
            string draft = field.Family == "text" ? a[1].TextValue : a[1].ToString();
            // Types are strict even when the offered initial value needs an edit.
            field.Draft(draft, initial: true);
            if (!values.TryAdd(role, draft)) throw new FormatException("Duplicate initial field.");
        }
        if (inputs.Count != values.Count) throw new FormatException("Incomplete initial fields.");
        return new(component, control, values);
    }
    public Term Fields(IReadOnlyDictionary<string, string> draft)
    {
        var inputs = Tree.Leaves.Where(c => c.Input).ToArray();
        if (draft.Count != inputs.Length || inputs.Any(c => !draft.ContainsKey(c.Role))) throw new FormatException("Incomplete draft.");
        return Term.List(inputs.Select(c => Term.Call("field", c.Id, c.Draft(draft[c.Role]))).ToArray());
    }
}

public sealed record Offer(string Name, Term Subject, Term Revision, Term ValuesToken, Form Form, string Availability)
{
    public static Offer[] Decode(string text, Term subject)
    {
        var root = Term.Parse(text); root.Ground(); var names = new HashSet<string>();
        return root.Items.Select(row => {
            var a = row.Require("operation_view", 9);
            if (a[0].Kind != "atom" || !names.Add(a[0].Name) || a[1].ToString() != subject.ToString() ||
                a[2].Kind != "binary" || a[2].Bytes.Length != 32 || a[4].Kind != "binary" || a[4].Bytes.Length != 32 ||
                a[7].Items.Any(x => x.Kind != "atom") || a[8].Kind != "atom" || a[8].Name is not ("available" or "unavailable" or "requires_input"))
                throw new FormatException("Invalid offered operation binding.");
            return new Offer(a[0].Name, a[1], a[2], a[4], Form.Decode(a[3], a[5], a[6]), a[8].Name);
        }).ToArray();
    }
    public string Goal(IReadOnlyDictionary<string, string> draft) => Term.Call("gui_operation", Subject, Term.Atom(Name), Revision, Form.Submit,
        Form.Fields(draft), Term.Variable("Results")) + ".";
}
