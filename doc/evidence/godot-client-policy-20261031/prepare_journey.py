"""Bind the accepted journey to software Control signals and the current server."""
import json,shutil
from pathlib import Path
from hashes import raw
ev=Path(__file__).resolve().parent
prior=ev.parent/'godot-client-reliability-package-20261031'
source=prior/'PackageJourneyChecks.cs'
text=source.read_text()
start=text.index('        // First observe real native input')
end=text.index('        async Task Reveal',start)
text=text[:start]+'''        // Software-only qualification: existing Control signals, no host input,
        // desktop/control focus, human-mode dispatch or alternate domain path.
        async Task ChooseOperation(OptionButton control,int index) {
            Check(index>0 && index<control.ItemCount,"existing authored choice is present");
            control.Select(index);control.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);
            await Frame();Check(control.Selected==index,"software selection reaches the existing authored-choice owner");
        }
        async Task Type(LineEdit line,string value) {
            line.Text=value;line.EmitSignal(LineEdit.SignalName.TextChanged,value);await Frame();
            Check(line.Text==value,"software text signal preserves the exact offered draft value");
        }
'''+text[end:]
start=text.index('            button.GrabFocus();')
end=text.index('        async Task Submit',start)
text=text[:start]+'''            int clicks=0;void Clicked(){clicks++;}button.Pressed+=Clicked;
            try {button.EmitSignal(BaseButton.SignalName.Pressed);await Frame();}
            finally {button.Pressed-=Clicked;}
            Check(clicks==1,"one software Control signal reaches the existing button owner");
        }
'''+text[end:]
assert 'M2_NATIVE_' not in text and '.GrabFocus(' not in text
text=text.replace('one actual native Submit','one software Control Submit').replace('native keyboard','software Control')
text=text.replace('existing native text input','existing Control text signal')
(ev/'PackageJourneyChecks.cs').write_text(text)
# Reuse the accepted source-only build owner without changing its phases.
shutil.copy2(prior/'build_companion.py',ev/'build_companion.py')
driver=(prior/'journey.py').read_text()
driver=driver.replace('from desktop_input import deliver\n','')
needle="m=json.loads(Path(sys.argv[2]).read_text());assert"
assert driver.count(needle)==1
driver=driver.replace(needle,"m=json.loads(Path(sys.argv[2]).read_text());server_stage=Path(sys.argv[3]);assert")
needle="'native_inputs':[],"
driver=driver.replace(needle,needle+"'host_input_or_focus_action':False,'software_Control_signals':True,")
start=driver.index("    server_label=label+'-server';")
end=driver.index('\n    while True:',start)
driver=driver[:start]+'''    server_label=label+'-server';server=start('server',['python3','-B',str(ev/'serve.py'),server_label,'--stage',str(server_stage),'--profile','test','--qualified','--clean-manifest',str(server_stage.parent/'source-manifest.json')]);deadline=time.monotonic()+60'''+driver[end:]
driver=driver.replace("if text.startswith('M2_NATIVE_'):","if text.startswith('M2_NATIVE_'):raise RuntimeError('host input is outside this software qualification')\n                if owner is None and text.startswith(('PASS ', 'M5_PACKAGE_JOURNEY_PASS')):")
driver=driver.replace("                    deliver(text,pid,True,record['native_inputs'])\n",'')
assert 'deliver(' not in driver
(ev/'journey.py').write_text(driver)
inputs={n:raw(prior/n) for n in ['PackageJourneyChecks.cs','build_companion.py','journey.py']}
outputs={n:raw(ev/n) for n in inputs}
(ev/'inputs/journey-composition.json').write_text(json.dumps({'accepted_owner_inputs':inputs,'composition':outputs,'product_source_changes':False,'host_input_or_focus':False,'software_Control_signal_scope':True},indent=2)+'\n')
print('Prepared current-server journey; no client or runtime launched.')
