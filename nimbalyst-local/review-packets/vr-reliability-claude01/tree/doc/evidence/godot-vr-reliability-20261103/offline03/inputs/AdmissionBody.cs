using System.Text.Json;
internal sealed partial class AdmissionCase {
public async Task Run() {
        static bool Finish(string? command)=>command==null||command.Trim() is "" or "finish" or "stop";
        RenderingServer.FramePostDraw+=Observe;
        try{
            using var admissionStop=new CancellationTokenSource();
            var admission=visualReady.Task.WaitAsync(admissionStop.Token);
            var command=Task.Run(Console.In.ReadLine);
            while(await Task.WhenAny(admission,command)!=admission){
                    var line=await command;
                    if(Finish(line)){
                        admissionStop.Cancel();
                        try{await admission;}catch(OperationCanceledException){}
                        RenderingServer.FramePostDraw-=Observe;
                        Report("VR263_FINISH",new{explicit_finish=true,during_admission=true});await app.CloseApplication();return;
                    }
                    if(line!.Trim()=="status")Report("VR263_STATUS",Snapshot());
                    command=Task.Run(Console.In.ReadLine);
                }
            await admission;
            await File.WriteAllTextAsync(folder+"/visual-ready.json",JsonSerializer.Serialize(Snapshot("visual")));
            while(true){var line=await command;if(Finish(line))break;if(line!.Trim()=="status")Report("VR263_STATUS",Snapshot());command=Task.Run(Console.In.ReadLine);}
        }finally{RenderingServer.FramePostDraw-=Observe;}
        Report("VR263_FINISH",new{explicit_finish=true});await app.CloseApplication();
}
}
