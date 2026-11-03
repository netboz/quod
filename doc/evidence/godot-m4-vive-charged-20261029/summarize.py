"""Bind completed hardware observations without replaying or recounting API dumps."""
import hashlib,json,os,sys
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-presentation-20261030'))
from digests import Digests,key
d=Digests();cases={}
for label,folder in [('native-vive-product06',ev.parent/'godot-m4-vive-physical-20261029'),('native-vive-product07',ev)]:
    r=json.loads((folder/label/'result.json').read_text());client=json.loads((folder/label/'client-result.json').read_text());last=client['snapshots'][-1]
    assert r['client_exit']==r['runtime_exit']==r['server_exit']==0 and all(r['eof'].values()) and not r['reader_errors'] and not r['runtime_processes_after'] and not r['diagnostics']
    assert not any(c.get('diagnostic_instruction') in ['sample','gui-check'] for c in r['commands'])
    dump=Path(r['api_dump']['path']);k=key(dump)
    assert k in d.values and d.values[k]==r['api_dump']['sha256'],'No raw API recount: require authenticated current stat key'
    assert dump.stat().st_mode&0o777==0o600 and dump.parent.stat().st_mode&0o777==0o700
    for row in r['streams'].values():
        p=Path(row['raw']);assert p.stat().st_mode&0o777==0o600 and d.h(p)==row['sha256']
    cases[label]={'diagnostic':True,'protocol_retirement_passed':r['passed'],'full_physical_accepted':False,'client_exit':r['client_exit'],'runtime_exit':r['runtime_exit'],'server_exit':r['server_exit'],'eof':r['eof'],'model_metrics_after':last['metrics'],'frames':last['frames'],'valid_head':last['validHead'],'high_head':last['highHead'],'sources':[{'hand':s['hand'],'profile':s['profile'],'current_predicate_frames':s['tracked_frames'],'internal_adjusted_transform_disagreements':s['pose_disagreements'],'raw_edges':len(s['edges'])} for s in last['sources']],'final_signed_state':{n:last['state'][n] for n in ['state','status','world_accepted','pending','busy']},'original_calibration_unchanged':r['original_calibration_unchanged'],'display_and_config_preserved':r['display_rule']['desktop_unchanged'] and r['display_rule']['config_unchanged'],'api_dump':{**r['api_dump'],'authenticated_current_stat_key':k,'unchanged_dump_rehashed_or_reparsed':False},'commands':r['commands'],'formal_ninety_draw_gate':'UNRUN','mapped_gui_gesture_or_movement':'UNRUN'}
record={'cases':cases,'human_case07':{'source':'actual coordinator PromptForUserInput completion forwarded in meta-1793316251211-5f0llo4','respondedBy':'desktop','respondedAt':1793316207996,'released_controls_during_observation':True,'current_readiness_inferred':False,'models_exact':'I could see both, but as they are all black they are hard to distinguish. I see the yello beam going out of them thougth','interface_exact':'too distant','both_models_and_yellow_beams_visible_on_physical04':True,'readable_gui_mapped_action_comfort_claim':False},'earlier_case06_human_failure_retained':True,'prior_frozen_handoff_and_question37_pending_label':'Historical. Actual desktop cancellation receipt retained separately at /data/quod-m4-vr-ca84d4f8-20261029/artifacts/vive-physical-freeze-runs01/question37-real-cancellation-and-new-continuation.json; no worker widget was opened in this continuation.','full_m4_accepted':False,'raw_room_geometry':'private0600 only; public relative observations retain actual distinct sample times and cached getter/native-status limits'}
target=ev/'inputs/completed-case06-07-summary.json';assert not target.exists();target.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'cases':{n:{'client':r['client_exit'],'runtime':r['runtime_exit'],'server':r['server_exit'],'source_frames':r['sources'],'final_signed_state':r['final_signed_state']} for n,r in cases.items()},'api_dumps_recounted':False,'full_m4_accepted':False}))
