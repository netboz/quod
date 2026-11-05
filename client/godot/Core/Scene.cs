using System.Numerics;

namespace Quod.Client;

// Exact descriptor values remain integers/fractions until the engine boundary.
public sealed record Length(BigInteger Numerator, BigInteger Denominator)
{
    public static Length Decode(Term value, bool rational)
    {
        BigInteger n, d;
        if (value.Kind == "number") { n = value.Integer; d = 1; }
        else {
            var a = value.Require("/", 2); n = a[0].Integer; d = a[1].Integer;
            if (!rational || d <= 1 || BigInteger.GreatestCommonDivisor(n, d) != 1) throw new FormatException("Expected a reduced exact length.");
        }
        if (n <= 0) throw new FormatException("Expected a positive length.");
        return new(n, d);
    }
    public float RenderMetres()
    {
        int nShift = checked((int)Math.Max(0, Numerator.GetBitLength() - 900));
        int dShift = checked((int)Math.Max(0, Denominator.GetBitLength() - 900));
        double value = Math.ScaleB((double)(Numerator >> nShift) / (double)(Denominator >> dShift), nShift - dShift) / 1000;
        float result = (float)value;
        if (!float.IsFinite(result) || result <= 0) throw new FormatException("Exact length is outside the engine's renderable range.");
        return result;
    }
}
public sealed record ScenePose(BigInteger[]? Transform, ulong? Body, ulong Revision, bool Reframed)
{
    public static ScenePose Decode(Term pose)
    {
        if (pose.Name is "body_pose" or "body_frame_pose") {
            var body = pose.Require(pose.Name, 2);
            ulong id = checked((ulong)body[0].Integer), revision = checked((ulong)body[1].Integer);
            if (revision == 0) throw new FormatException("Invalid body revision.");
            return new(null, id, revision, pose.Name == "body_frame_pose");
        }
        var values = pose.Require("transform", 6).Select(x => x.Integer).ToArray();
        if (values.Skip(3).Any(x => x < 0 || x >= 360)) throw new FormatException("Invalid scene rotation.");
        return new(values, null, 0, false);
    }
}
public sealed record SceneMark(string Id, string Kind, Length[] Size, string? Parent, ScenePose Pose, string Colour, int Metallic, int Roughness, int Emission, int Opacity, Term Label, Term? Subject, string Signature)
{
    public static SceneMark[] Decode(Term scene)
    {
        scene.Ground(); var seen = new HashSet<string>();
        return scene.Items.Select(term => {
            var a = term.Require("mark", 7); string id = a[0].TextValue, kind = a[1].TextValue;
            if (id.Length == 0 || !seen.Add(id)) throw new FormatException("Empty or duplicate occurrence identity.");
            string? parent = null; var pose = a[3];
            if (pose.Name == "relative") {
                var relative = pose.Require("relative", 2); parent = relative[0].TextValue; pose = relative[1];
                if (parent == id || !seen.Contains(parent)) throw new FormatException("Missing, cyclic or unordered scene parent.");
            }
            var transform = ScenePose.Decode(pose);
            string[] fields = kind switch {
                "box" or "wire_box" => ["width", "height", "depth"],
                "sphere" => ["diameter"],
                "group" => [], _ => throw new FormatException("Unsupported scene geometry: " + kind) };
            if (a[2].Items.Length != fields.Length) throw new FormatException("Wrong geometry field count.");
            var sizes = a[2].Items.Select((row, i) => {
                var f = row.Require("f", 2);
                if (f[0].TextValue != fields[i]) throw new FormatException("Wrong geometry field order.");
                return Length.Decode(f[1], kind == "wire_box");
            }).ToArray();
            string colour = "#6A90D9";
            int metallic=0,roughness=0,emission=0,opacity=1000;
            if (kind == "group") {
                if (a[4].Kind != "atom" || a[4].Name != "no_surface") throw new FormatException("Group has a surface.");
            } else {
                var surface = a[4].Require("surface", 6); colour = surface[0].TextValue;
                if (!System.Text.RegularExpressions.Regex.IsMatch(colour, "^#[0-9A-F]{6}$") ||
                    surface.Skip(1).Take(4).Any(v => v.Integer < 0 || v.Integer > 1000) || surface[5].Items.Length != 0)
                    throw new FormatException("Unsupported or invalid scene surface.");
                metallic=(int)surface[1].Integer;roughness=(int)surface[2].Integer;emission=(int)surface[3].Integer;opacity=(int)surface[4].Integer;
            }
            var label = a[5];
            if (label.Kind != "atom" || label.Name != "unlabelled") {
                var l = label.Require("label", 2); _ = l[0].TextValue;
                if (l[1].TextValue is not ("above" or "centre" or "below")) throw new FormatException("Unsupported label placement.");
            }
            Term? subject = null;
            if (a[6].Kind != "atom" || a[6].Name != "depicts_nothing") {
                var depicts = a[6].Require("depicts", 3);
                if (depicts[0].TextValue.Length == 0 || depicts[1].Kind != "binary" || depicts[1].Bytes.Length != 32) throw new FormatException("Missing exact depicted history.");
                var local=depicts[2];
                subject = (local.Name=="ontology_ref" && local.Args.Length==2 || local.Name is "class_ref" && local.Args.Length==3) &&
                    local.Args[0].ToString()==depicts[0].ToString() && local.Args[1].ToString()==depicts[1].ToString()
                    ? local : Term.Call("entity_ref", depicts);
            }
            if (transform.Body != null && subject == null) throw new FormatException("A body occurrence requires an exact subject.");
            return new SceneMark(id, kind, sizes, parent, transform, colour, metallic, roughness, emission, opacity, label, subject, term.ToString());
        }).ToArray();
    }
}
