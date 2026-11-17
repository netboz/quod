namespace Quod.Client;

// Exact subject data is shared by picking, authored choices and their consumers.
// Ontology identity is never converted into space membership.
public sealed record Subject(Term Exact, Actor Target, Term Local)
{
    public Term? Predicate=>Exact.Name=="predicate_ref" ? Exact.Args[2] : null;
    public static Subject Decode(Term exact)
    {
        exact.Ground();
        if (exact.Name is "entity_ref" or "agent_instance_ref" or "class_ref") {
            var a=exact.Require(exact.Name,3);var target=new Actor(a[0].TextValue,Identity.Encode(a[1].Bytes),a[2]+".");
            if(a[1].Kind!="binary" || a[1].Bytes.Length!=32 || target.Namespace.Length==0)throw new FormatException("Invalid subject identity.");
            return new(exact,target,a[2]);
        }
        if(exact.Name=="predicate_ref") {
            var p=exact.Require("predicate_ref",3);var indicator=p[2].Require("/",2);
            if(indicator[0].Kind!="atom" || indicator[1].Integer<0)throw new FormatException("Invalid predicate indicator.");
            return new(exact,Decode(Term.Call("ontology_ref",p[0],p[1])).Target,exact);
        }
        var o=exact.Require("ontology_ref",2);
        if(o[1].Kind!="binary" || o[1].Bytes.Length!=32 || o[0].TextValue.Length==0)throw new FormatException("Invalid ontology identity.");
        return new(exact,new(o[0].TextValue,Identity.Encode(o[1].Bytes),"me."),exact);
    }
}

public sealed record Eidolon(Term Exact,Term Purpose,string Style,Actor Recipe)
{
    public bool Operation=>Purpose.Name=="operation" && Purpose.Args.Length==1;
    public string Caption=>string.Join(" · ",new[]{Operation ? "Action" : Purpose.Name,Style.Replace('_',' ')});
    public static Eidolon[] Decode(string text)
    {
        var value=Term.Parse(text);value.Ground();
        var choices=value.Items.Select(t=> {
            var e=t.Require("eidolon",3);var r=e[2].Require("recipe",3);
            if(e[1].Kind!="atom" || r[2].Kind!="atom")throw new FormatException("Unsupported Eidolon identity.");
            var recipe=Actor.FromTerm(Term.Call("entity_ref",r));
            return new Eidolon(t,e[0],e[1].Name,recipe);
        }).ToArray();
        if(choices.Select(c=>c.Exact.ToString()).Distinct().Count()!=choices.Length)throw new FormatException("Duplicate representation choice.");
        return choices;
    }
    public Term Read(Term entity)=>Term.Call("client_eidolon",entity,Exact,Term.Variable("View"));
}
