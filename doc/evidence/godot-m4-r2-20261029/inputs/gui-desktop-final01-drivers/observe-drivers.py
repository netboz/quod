"""Retain exact removable diagnostic changes to the existing journey callers."""
import difflib,hashlib,json

def instrument(path):
    original=path.read_text();text=original
    def replace(before,after):
        nonlocal text
        assert text.count(before)==1,(path.name,before)
        text=text.replace(before,after)
    replace('from desktop_input import deliver','from desktop_input import deliver\nfrom shutdown_observation import ShutdownObservation, allow_owned_trace')
    # The ordinary headless window defaults to 64x64, outside the actual form's
    # pointer target. Set the generic engine window size; keep every GUI check.
    replace("['--headless']", "['--headless','--resolution','1920x1080']")
    if path.name=='journey.py':
        replace('env=env, text=True)','env=env, text=True, preexec_fn=allow_owned_trace)')
        replace('        def read_output():\n            for line in child.stdout:\n                output.put(line)\n            output.put(None)\n        threading.Thread(target=read_output, daemon=True).start()',
                '        reader_errors=[]\n        def read_output():\n            try:\n                for line in child.stdout:output.put(line)\n            except Exception as error:reader_errors.append(type(error).__name__)\n            finally:output.put(None)\n        reader=threading.Thread(target=read_output);reader.start()\n        observation=ShutdownObservation(child,a.private/(phase+"-shutdown-diagnostic"))')
        replace("                text += line\n", "                text += line\n                observation.observe(line)\n")
        replace("                    actual = child.wait(timeout=10)\n", "                    actual = child.wait(timeout=10)\n                    observation.finish();reader.join(timeout=5)\n")
        replace("                        child.kill(); child.wait()\n", "                        child.kill(); child.wait();observation.finish();reader.join(timeout=5)\n")
        replace('        exit_code = child.wait(timeout=10)', '        exit_code = child.wait(timeout=10)\n        shutdown_observation=observation.finish();reader.join(timeout=5)')
        replace("'godot_error_diagnostics': 'ERROR:' in text, 'passed': exit_code == expected and 'ERROR:' not in text}",
                "'godot_error_diagnostics': 'ERROR:' in text, 'shutdown_observation': shutdown_observation, 'output_eof':not reader.is_alive(), 'reader_errors':reader_errors, 'passed': exit_code == expected and 'ERROR:' not in text and not reader.is_alive() and not reader_errors}")
    else:
        assert path.name=='local.py'
        start=text.index('            except queue.Empty:')
        end=text.index('            if line is None: break',start)
        text=text[:start]+'''            except queue.Empty:
                child.kill();child.wait();observation.finish();reader.join(timeout=5)
                records.append({'command':command,'child_exit':child.returncode,'watchdog':True,'shutdown_observation':observation.receipt})
                raise RuntimeError('No progress before original watchdog')
'''+text[end:]
        replace('    def receive():\n        for line in child.stdout: lines.put(line)\n        lines.put(None)\n    threading.Thread(target=receive, daemon=True).start()',
                '    reader_errors=[]\n    def receive():\n        try:\n            for line in child.stdout:lines.put(line)\n        except Exception as error:reader_errors.append(type(error).__name__)\n        finally:lines.put(None)\n    reader=threading.Thread(target=receive);reader.start()\n    observation=ShutdownObservation(child,a.private/(label+"-shutdown-diagnostic"))')
        replace("            log.write(line); log.flush(); text += line; print(line.rstrip(), flush=True)","            log.write(line); log.flush(); text += line; print(line.rstrip(), flush=True);observation.observe(line)")
        replace("                child.kill();child.wait();records.append(","                child.kill();child.wait();observation.finish();reader.join(timeout=5);records.append(")
        replace('    child.wait()\n    passed =', '    child.wait()\n    shutdown_observation=observation.finish();reader.join(timeout=5)\n    passed =')
        replace("and 'ERROR:' not in text and (killed", "and 'ERROR:' not in text and not reader.is_alive() and not reader_errors and (killed")
        replace("'external_sigkill_at_observed_seam': killed, 'passed': passed", "'external_sigkill_at_observed_seam': killed, 'shutdown_observation':shutdown_observation, 'output_eof':not reader.is_alive(), 'reader_errors':reader_errors, 'passed': passed")
    path.write_text(text)
    return {'original_sha256':hashlib.sha256(original.encode()).hexdigest(),'supplied_sha256':hashlib.sha256(text.encode()).hexdigest(),
            'purpose':'Bounded argument-free observation before unchanged watchdogs; output-reader completion/error ownership; unchanged product assertions and authority',
            'diff':''.join(difflib.unified_diff(original.splitlines(True),text.splitlines(True),fromfile='original/'+path.name,tofile='supplied/'+path.name))}
