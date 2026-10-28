using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;

namespace Quod.Client;

// A data codec for functional projection terms. Authored goals are parsed only
// by the server. Integers and binary values never pass through Godot Variant.
public sealed record Term(string Kind, string Name, Term[] Args, byte[] Bytes)
{
    public static Term Atom(string name) => new("atom", name, [], []);
    public static Term Variable(string name) => new("variable", name, [], []);
    public static Term Number(string value) => new("number", value, [], []);
    public static Term Binary(byte[] bytes) => new("binary", "", [], bytes);
    public static Term Text(string value) => Binary(Encoding.UTF8.GetBytes(value));
    public static Term Call(string name, params Term[] args) => new("compound", name, args, []);
    public static Term List(params Term[] items) => new("list", "", items, []);
    public Term[] Require(string name, int arity) => Kind == "compound" && Name == name && Args.Length == arity
        ? Args : throw new FormatException($"Expected {name}/{arity}.");
    public string TextValue => Kind == "binary" ? new UTF8Encoding(false, true).GetString(Bytes)
        : throw new FormatException("Expected binary text.");
    public BigInteger Integer => Kind == "number" && Regex.IsMatch(Name, @"^-?\d+$")
        ? BigInteger.Parse(Name, CultureInfo.InvariantCulture) : throw new FormatException("Expected integer.");
    public Term[] Items => Kind == "list" ? Args : throw new FormatException("Expected a proper list.");
    public void Ground()
    {
        if (Kind is "variable" or "partial") throw new FormatException("Projection must be ground and proper.");
        foreach (var a in Args) a.Ground();
    }
    static string Quote(string value) => "'" + value.Replace("\\", "\\\\").Replace("'", "\\'")
        .Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t") + "'";
    static string AtomText(string value) => Regex.IsMatch(value, @"^[a-z][A-Za-z0-9_]*$") ? value : Quote(value);
    public override string ToString() => Kind switch
    {
        "atom" => AtomText(Name), "variable" or "number" => Name,
        "binary" => "<<\"" + string.Concat(Bytes.Select(b => b switch {
            34 => "\\\"", 92 => "\\\\", 10 => "\\n", 13 => "\\r", 9 => "\\t",
            >= 32 and <= 126 => ((char)b).ToString(), _ => "\\x" + b.ToString("x2") + "\\" })) + "\">>",
        "compound" => AtomText(Name) + "(" + string.Join(",", Args.Select(a => a.ToString())) + ")",
        "list" => "[" + string.Join(",", Args.Select(a => a.ToString())) + "]",
        "partial" => "[" + string.Join(",", Args[..^1].Select(a => a.ToString())) + "|" + Args[^1] + "]",
        _ => throw new FormatException("Unsupported term.")
    };
    public static Term Parse(string source)
    {
        var reader = new Reader(source); var value = reader.One(0); reader.Space();
        if (reader.At != source.Length) throw new FormatException("Trailing projection text.");
        return value;
    }
    sealed class Reader(string source)
    {
        public int At;
        public void Space() { while (At < source.Length && char.IsWhiteSpace(source[At])) At++; }
        bool Take(string s) { if (!source.AsSpan(At).StartsWith(s)) return false; At += s.Length; return true; }
        char Next() => At < source.Length ? source[At++] : throw new FormatException("Incomplete term.");
        int Escape()
        {
            char c = Next();
            if (c == 'x') {
                int start = At; while (At < source.Length && Uri.IsHexDigit(source[At])) At++;
                if (start == At || Next() != '\\') throw new FormatException("Invalid hex escape.");
                int value = int.Parse(source.AsSpan(start, At - start - 1), NumberStyles.HexNumber);
                if (!Rune.IsValid(value)) throw new FormatException("Invalid escaped character.");
                return value;
            }
            return c switch { 'n' => 10, 'r' => 13, 't' => 9, 'b' => 8, 'f' => 12, 'v' => 11,
                '\\' => 92, '\'' => 39, '"' => 34, _ => throw new FormatException("Unsupported escape.") };
        }
        string Quoted(char end)
        {
            var result = new StringBuilder();
            for (;;) { char c = Next(); if (c == end) return result.ToString();
                result.Append(c == '\\' ? char.ConvertFromUtf32(Escape()) : c.ToString()); }
        }
        public Term One(int depth)
        {
            // include/quod_term_limits.hrl: lists count elements, not their spine.
            if (depth > 64) throw new FormatException("Term exceeds protocol depth.");
            Space();
            if (Take("<<\"")) {
                var bytes = new List<byte>();
                for (;;) {
                    char c = Next(); if (c == '"') { if (!Take(">>")) throw new FormatException("Binary terminator."); break; }
                    int b = c == '\\' ? Escape() : c;
                    if (b > 255) throw new FormatException("Invalid binary byte."); bytes.Add((byte)b);
                }
                return Binary(bytes.ToArray());
            }
            if (Take("[")) {
                var items = new List<Term>(); Space(); if (Take("]")) return List();
                for (;;) {
                    items.Add(One(depth + 1)); Space(); if (Take("]")) return List(items.ToArray());
                    if (Take("|")) { items.Add(One(depth + 1)); Space(); if (!Take("]")) throw new FormatException("List tail.");
                        return new("partial", "", items.ToArray(), []); }
                    if (!Take(",")) throw new FormatException("Expected list separator.");
                }
            }
            var match = Regex.Match(source[At..], @"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?");
            if (match.Success) { At += match.Length; return Number(match.Value); }
            string name;
            if (Take("'")) name = Quoted('\'');
            else {
                match = Regex.Match(source[At..], @"^[a-zA-Z_][A-Za-z0-9_]*");
                if (!match.Success) throw new FormatException($"Invalid functional term at {At}.");
                name = match.Value; At += match.Length;
                if (char.IsUpper(name[0]) || name[0] == '_') return Variable(name);
            }
            if (!Take("(")) return Atom(name);
            var args = new List<Term>();
            for (;;) { args.Add(One(depth + 1)); Space(); if (Take(")")) return Call(name, args.ToArray());
                if (!Take(",")) throw new FormatException("Expected argument separator."); }
        }
    }
}
