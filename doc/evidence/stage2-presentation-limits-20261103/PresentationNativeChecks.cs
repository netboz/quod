using Godot;
using Quod.Client;
public partial class ExportChecks {
 async Task PresentationNativeChecks() {
  var scene=new ScenePanel();app.AddChild(scene);
  string label=new string('L',300),ns=new string('n',90),id=new string('i',300),anchor=string.Concat(Enumerable.Repeat("\\x7\\",32));
  string Mark(int i)=>$"mark(<<\"{id}{i}\">>,<<\"box\">>,[f(<<\"width\">>,100001),f(<<\"height\">>,10),f(<<\"depth\">>,10)],transform({1000001+i*200000},0,0,0,0,0),surface(<<\"#FFFFFF\">>,0,900,0,[]),label(<<\"{label}\">>,<<\"above\">>),depicts(<<\"{ns}\">>,<<\"{anchor}\">>,item({i})))";
  var terms=Term.Parse("["+string.Join(",",Enumerable.Range(0,600).Select(Mark))+"]");
  scene.Apply(terms);Check(scene.Count==600,"native shared adapter installs every mark beyond 512 with full long identifiers and large finite geometry");
  var subject=SceneMark.Decode(terms)[599].Subject!;var occurrence=scene.SubjectIds(subject).Single();var pose=scene.WorldPose(occurrence);
  Check(scene.SubjectLabel(subject)==label,"native full label survives without producer truncation");
  var picked=scene.PickRay(pose.Origin+new Vector3(0,0,3),Vector3.Forward);
  Check(picked?.Subject.ToString()==subject.ToString(),"native picking preserves exact long namespace and ordinary subject");
  int rebuilt=scene.Rebuilt;scene.Apply(terms);scene.Apply(terms);Check(scene.Rebuilt==rebuilt,"unchanged complete scene reuses existing geometry");
  var field=Component.Decode(Term.Parse("component(note,text_area,[property(label,<<\"Note\">>),property(required,false)],[])"));
  Check(field.Draft(new string('x',5000)).TextValue.Length==5000,"native text control admits full text without an authored max_bytes");
  bool refused=false;try {Component.Decode(Term.Parse("component(note,text_area,[property(label,<<\"Note\">>),property(required,false),property(max_bytes,12)],[])")).Draft(new string('x',13));}catch(FormatException){refused=true;}
  Check(refused,"native text control still enforces an explicit authored allowance");
  scene.Withdraw();Check(scene.Count==0&&picked?.Pose==null,"withdrawal retires large-scene occurrences and stale picks");
  scene.QueueFree();await Frame();
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
