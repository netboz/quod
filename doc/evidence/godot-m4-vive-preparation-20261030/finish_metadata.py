"""Write structured offline preparation receipts without interpreting prose as code."""
import ast,hashlib,json,pathlib
e=pathlib.Path(__file__).resolve().parent
data=json.loads((e/'inputs/metadata-authoring-inputs.json').read_text())
for n,v in data.items():
 with (e/n).open('x') as f:
  if isinstance(v,str):f.write(v)
  else:json.dump(v,f,indent=2);f.write('\n')
m=json.loads((e/'inputs/client-physical-preparation01-manifest.json').read_text())
v=json.loads((e/'inputs/build-verification02.json').read_text())
q={'checkpoint':'QUO-65 offline corrected diagnostic preparation',
 'worker':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f','actual_api_model':'openai-codex:gpt-6.1-sol',
 'launcher_effort':'max','effective_backend_effort':'unexposed','build_passed':True,
 'metadata_verification02_passed':True,'metadata_verification01':'FAILED report path; retained',
 'metadata_authoring01':'FAILED transient script syntax before execution; retained',
 'accepted_current_inputs':92,'supplied_diagnostic_inputs':93,'exports':196,
 'true_build_command_exits':[0,0,0,0,0],'build_driver_exit':0,'build_wrapper_exit':0,
 'explicit_completion':True,'timeout':False,'eof':{'stdout':True,'stderr':True},'reader_errors':[],
 'live_production_changes':0,'staged_dispatch_override':'client/godot/tests/ExportChecks.cs',
 'added_unchanged_partial_sha256':'dea82a9dec22e51de3ee67b9ccb18b5e6ca4b6f5c5aee000422c14acb2304898',
 'dll':v['dll'],'pck':v['pck'],'template':v['engine'],'distributable':False,
 'functional_application_executed':False,'native_runtime_started':False,
 'hardware_queried':False,'display_mutated':False,'human_question_opened':False,
 'gui_tests_repeated':False,'core189_repeated':False,'server1432_repeated':False,
 'engine_or_monado_rebuilt':False,'physical_qualification':'UNRUN',
 'remaining':['Yan actual return/readiness in sole coordinator chat',
 'current signed ordinary app/runtime/window readiness after coordinator acceptance',
 'corrected-payload readability and controller contrast human observation',
 'contemporaneous canonical head/bothwand/neutral and formal90draw qualification',
 'signed mapped GUI/subject/model/movement interactions',
 'physical focus/disconnect/reentry/retirement/platform exit and comfort'],
 'historical_desktop_stalls_resolved':False,'full_m4_accepted':False,'commit':False,'M5':False,
 'freeze_result':'External vive-preparation-freeze-runs01/result.json determines actual completion.'}
(e/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
sources={}
for p in e.glob('*.py'):
 ast.parse(p.read_text(),filename=str(p))
 sources[str(p)]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size}
(e/'inputs/final-helper-syntax.json').write_text(json.dumps({'passed':True,'method':'ast.parse only; no functional test','sources':sources},indent=2)+'\n')
print(json.dumps({'metadata_written':True,'helpers_syntax_checked':len(sources),'production_changes':0,'diagnostic_supplied_inputs':len(m['supplied_inputs'])}))
