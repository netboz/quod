"""Prepare the existing candidate refounding workflow; no network mutations."""
from pathlib import Path
import json
import shutil

root = Path('/home/yan/src/quod')
old = root / '_build/lobby-safety-20261016/deployment-01'
out = root / '_build/world-library-20261016/deployment-01'
out.mkdir(exist_ok=False)
(out / 'refound').mkdir()
tree = root / '_build/world-library-20261016/clean-integration-02/tree'

def changed(text, before, after, count=1):
    assert text.count(before) == count, (before, text.count(before), count)
    return text.replace(before, after)

for name in ['prepare_refound.py', 'create_new_volumes.py', 'bootstrap.py',
             'install_remaining.py', 'scale_out.py', 'watch_deployment.py',
             'fleet_probe.py', 'purge_old_volumes.py']:
    text = (old / name).read_text().replace(str(old), str(out))
    if name == 'prepare_refound.py':
        text = changed(text, "old_family = job_id + '-refound-20261015-v8'", "old_family = job_id + '-refound-20261016-v9'")
        text = changed(text, "new_family = job_id + '-refound-20261016-v9'", "new_family = job_id + '-refound-20261017-v10'")
        text = changed(text, '0.7.270@sha256:b38b552327ec53ea3977167ff387b0cd5377ad86b3dd3d0a04656711bdf1ab16', '0.7.272@sha256:44efbe7be43c73d2e80d923cd492771d6793dcc9556281c07e1d249b6f76a4c5')
        text = changed(text, "candidate['Version'] == 88 and candidate['JobModifyIndex'] == 863647", "candidate['Version'] == 91 and candidate['JobModifyIndex'] == 866029")
        text = changed(text, "source_commit = json.loads((out.parent/'source-commit.json').read_text())['commit']\ntext = subprocess.check_output(['git','show',source_commit+':deploy/quod.nomad'],cwd=repo,text=True)", f"tree = Path({str(tree)!r})\ntext = (tree/'deploy/quod.nomad').read_text()")
        text = changed(text, "template = subprocess.check_output(['git','show',source_commit+':deploy/volumes/quod-node-local.hcl'],cwd=repo,text=True)", "template = (tree/'deploy/volumes/quod-node-local.hcl').read_text()")
    if name == 'fleet_probe.py':
        text = changed(text, "p['version'] == '0.7.271'", "p['version'] == '0.7.273'")
    if name == 'purge_old_volumes.py':
        text = changed(text, "desktop-04/PASSED.json", "desktop-01/PASSED.json")
    (out / name).write_text(text)

for name in ['fresh_system_operator.py', 'quod_fresh_systems.erl']:
    text = (old / 'refound' / name).read_text().replace(str(old), str(out))
    if name == 'fresh_system_operator.py':
        text = changed(text, "if name=='lobby': return [", "if name=='lobby': return [\n        dep('names_vocabulary','names'),")
    else:
        text = changed(text, '"quod_physics.pl", "space_view.pl"]],',
                       '"quod_physics.pl", "space_view.pl", "voxel_world.pl", "voxel_world_view.pl",\n'
                       '                    "gui_instance.pl", "gui_question.pl", "voxel_world_gui.pl", "lobby_worlds.pl"]],')
        text = changed(text, '    {ok, Template} = file:read_file(path("human_user_instance.pl")),',
                       '    Sources = [{user_source_file, list_to_binary(path(File))}\n'
                       '        || File <- ["human_user_instance.pl", "gui_hud.pl"]],')
        text = changed(text, '    [{user_template, Template}, {signup_host, Node} | Dependencies];',
                       '    Sources ++ [{signup_host, Node} | Dependencies];')
    (out / 'refound' / name).write_text(text)

shutil.copy2(old/'quod_vault_boot_probe.erl', out/'quod_vault_boot_probe.erl')
text = (old/'boot_probe.py').read_text()
text = changed(text, "assert Path('/home/yan/src/quod/deploy/quod.nomad').read_bytes() == subprocess.check_output(['git','show',json.loads((out/'source-commit.json').read_text())['commit']+':deploy/quod.nomad'])",
               f"template = Path({str(tree/'deploy/quod.nomad')!r})\nassert template.read_bytes() == Path('/home/yan/src/quod/deploy/quod.nomad').read_bytes()")
text = changed(text, "str(Path('/home/yan/src/quod/deploy/quod.nomad'))", "str(template)")
(out/'boot_probe.py').write_text(text)
(out/'preparation.json').write_text(json.dumps({
    'source_workflow': str(old), 'frozen_tree': str(tree),
    'release': '0.7.273', 'authority': 'doc/evidence/world-library-20261016/overnight-authority.md',
    'remote_mutations': False,
    'changes': ['separate exact source manifest instead of a commit claim',
                'candidate v91 image 272 and volume family v9 -> reviewed image 273 and family v10',
                'compose terrain/library source, naming vocabulary and human HUD',
                'retain old volumes until fleet and desktop acceptance']}, indent=2)+'\n')
print(out)
