using Godot;
using Quod.Client;
using System.Text.Json;
using Json=Quod.Client.Json;
using File=System.IO.File;

// Removable signed occurrence/form qualification. No hardware input.
public partial class ExportChecks
{
    void OccurrencePoint(SpatialGui gui,Control control)
    {
        var point=control.GetGlobalRect().GetCenter();
        if(control.GetViewport()==gui.FormSurface) {
            if(gui.Spatial){gui.Move(point,gui.FormSurface);return;}
            point=gui.FormMirror.GlobalPosition+point/(Vector2)gui.FormSize*gui.FormMirror.Size;
        }
        gui.Move(point);
    }
    async Task OccurrenceChecks()
    {
        bool invalidBytes=false;try{_ = Term.Parse("<<\"\u00b7\">>").TextValue;}catch(System.Text.DecoderFallbackException){invalidBytes=true;}
        Check(invalidBytes,"native term decoder refuses the earlier fixture's literal non-UTF8 binary separator");
        GetTree().Root.Size=new(1200,800);await Frame();
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        if(Env("M1B_PHASE")=="visibility-question") {
            await QuestionVisibilityChecks();await CompleteOccurrenceChecks();return;
        }
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        var s0=Actor.FromTerm(app.ActiveAccounts.Setup!.Require("account",6)[2]);
        string ns=Term.Text(human.Namespace).ToString(),anchor=Term.Binary(Identity.Decode(human.Anchor)).ToString();
        var subject=(human with {InstanceText="analyzer."}).Entity;
        string parts="[part(<<\"left\">>,box(500,500,500),transform(-700,0,0,15,25,0),surface(<<\"#6A90D9\">>,0,700,0,[]),label(<<\"Same Analyzer - left\">>,<<\"above\">>),depicts_nothing),part(<<\"right\">>,box(500,500,500),transform(700,0,0,15,25,0),surface(<<\"#60C880\">>,0,700,0,[]),label(<<\"Same Analyzer - right\">>,<<\"above\">>),depicts_nothing)]";
        string[] clauses=[
            "isa(occurrence_instrument,thing)","instance_of(occurrence_instrument,analyzer)",
            "class_permission(occurrence_instrument,configure,allow)",
            $"class_eidolon(occurrence_instrument,operation(instance),configure,recipe({ns},{anchor},instrument_form))",
            $"eidolon(instrument_form,subject(ontology_ref({ns},{anchor}),instance(analyzer)),operation(instrument_settings))",
            $"entity_scene(analyzer,playing,appearance(analyzer,solid,analyzer,transform(0,0,0,0,0,0),[eidolon(playing,solid,recipe({ns},{anchor},instrument_solid))]))",
            $"eidolon(instrument_solid,analyzer,{parts})",
            $"space_contains({Term.Parse(s0.InstanceText.TrimEnd('.'))},{subject})",
            "instance_of(quod:gui:form,instrument_settings)","instance_of(quod:gui:text_box,run_name)","instance_of(quod:gui:button,apply_configuration)",
            "instance_of(quod:gui:group,measurement_settings)","gui_children(measurement_settings,[run_name])",
            "attribute(measurement_settings,label,<<\"Measurement\">>)",
            "gui_children(instrument_settings,[measurement_settings,apply_configuration])",
            "attribute(instrument_settings,label,<<\"Analyzer settings\">>)","attribute(instrument_settings,help,<<\"Both views share these settings. Changes stay local until Apply configuration.\">>)",
            "attribute(run_name,label,<<\"Run name\">>)","attribute(apply_configuration,label,<<\"Apply configuration\">>)",
            "gui_form(instrument_settings,[field(run_name,Name)],submit(apply_configuration,assertz(instrument_configuration(Name)),operation(configure,[])))",
            "gui_initial(instrument_settings,run_name,<<\"Sweep A\">>)"
        ];
        var result=await ExecuteComplete(session,app.ActiveStore,human,"transaction(("+string.Join(",",clauses.Select(c=>"assertz(("+c+" :- true))"))+" )).",CancellationToken.None);
        Check(Json.Committed(result),"authorized same-ontology fixture offers a non-space instance form and two visual occurrences");
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(subject).Length==2);
        await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        var ids=scene.SubjectIds(subject).Order().ToArray();
        object first=scene.Pick(scene.Project(ids[0],Vector3.Zero))!,second=scene.Pick(scene.Project(ids[1],Vector3.Zero))!;
        object? Property(object value,string name)=>value.GetType().GetProperty(name)?.GetValue(value);
        string Exact(object value)=>value is Term t ? t.ToString() : Property(value,"Subject")?.ToString()??"";
        using(var image=scene.Viewport.GetTexture().GetImage())Check(image.SavePng("/work/two-occurrences.png")==Error.Ok,"actual two-occurrence native raster retained");
        var observations=new {subject=subject.ToString(),ids,poses=ids.Select(id=>scene.WorldPose(id).ToString()).ToArray(),
            firstType=first.GetType().Name,secondType=second.GetType().Name,firstSubject=Exact(first),secondSubject=Exact(second),
            firstOccurrence=Property(first,"Id")?.ToString(),secondOccurrence=Property(second,"Id")?.ToString(),
            firstPose=Property(first,"Pose")?.ToString(),secondPose=Property(second,"Pose")?.ToString()};
        await File.WriteAllTextAsync("/work/selection.json",JsonSerializer.Serialize(observations));
        Check(Exact(first)==subject.ToString()&&Exact(second)==subject.ToString(),"both real native picks resolve the same exact anchored subject");
        Check(Property(first,"Id")?.ToString()==ids[0]&&Property(second,"Id")?.ToString()==ids[1]&&Property(first,"Pose")!=null&&Property(second,"Pose")!=null,
            "native selection retains each chosen visual occurrence and pose alongside the same subject");
        if(Env("M1B_PHASE")=="visibility-interaction")await OccurrenceInteraction(scene,subject,ids,parts);
        else if(Env("M1B_PHASE")=="visibility-preview")await OccurrencePreview(scene,subject,ids);
        else await VisibilityChecks(scene,subject,ids);
        await CompleteOccurrenceChecks();
    }
    async Task CompleteOccurrenceChecks()
    {
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"signed occurrence consumers retire through the existing owner");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("OCCURRENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
