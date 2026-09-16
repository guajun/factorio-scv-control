#!/usr/bin/env python3
"""Package and validate a single GUI lab save without ever opening the GUI."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import shutil
import tempfile
import time

from canonical import content_hash
from compare_saved import CASE_IDS, check_matrix, source_cases, verify_result
from live import executable_path, json_text
from rcon import RconError
from savebench import copy_mods, manual_profile, mod_fingerprint, read_json, relative_file, server, sha256, wait_save
from solve import lua_module

PROTOCOL = 'scv-unified-lab/1'
SCENARIO = 'scv-control-testkit/unified-lab'
EXTERNAL = ('grid-astar', 'grid-dijkstra', 'source-polygons')


def rpc(client, operation, **fields):
    value = json.loads(client.command('/scv-lab-agent ' + json_text({
        'protocol': PROTOCOL, 'operation': operation, **fields})).strip())
    if not isinstance(value, dict) or value.get('ok') is not True:
        raise ValueError('unified lab rejected: ' + json_text(value))
    return value


def references(report_path: Path) -> dict:
    report = read_json(report_path)
    if report.get('passed') != 44 or report.get('failed') != 0 or report.get('matrix_passed') is not True:
        raise ValueError('recordings require a complete validated 44-row comparison')
    corpus = Path(report['source_corpus']).resolve(strict=True)
    cases = source_cases(corpus, read_json(corpus / 'manifest.json'))
    rows = report['rows']
    check_matrix(rows, cases, ['production-v1', *EXTERNAL])
    by_id = {c['id']: c for c in cases}
    for row in rows:
        if row.get('passed') is not True or not verify_result(row['native_report'], by_id[row['case_id']], row['algorithm']):
            raise ValueError('recording matrix includes a nonpassing native result')
        native_report = row['native_report']
        if row.get('capture_identity') != [native_report.get('source_snapshot_hash'), native_report.get('source_query_hash')]:
            raise ValueError('recording native capture identity differs from comparison row')
    output = {'schema_version': 1, 'comparison_sha256': sha256(report_path), 'cases': []}
    for source in cases:
        item = {key: source[key] for key in ('id', 'facts_hash', 'save_sha256')}
        item.update(source_facts_hash=item.pop('facts_hash'), source_save_sha256=item.pop('save_sha256'),
                    fixture_version=4, algorithms={})
        for algorithm in EXTERNAL:
            row = next(r for r in rows if r['case_id'] == source['id'] and r['algorithm'] == algorithm)
            native = row['native_report']
            if not row['passed'] or row['source_facts_hash'] != source['facts_hash'] \
                    or row['source_save_sha256'] != source['save_sha256'] \
                    or native['source_verified'] is not True or native['runtime_build_calls'] != 0:
                raise ValueError('recording source is not a passing loaded-map result')
            plan = native['plans'][-1]
            complete = native['native']['outcome'] == 'arrived'
            if complete is not source['expected_path'] or plan['outcome'] != ('success' if complete else 'no-path'):
                raise ValueError('recording terminal differs from source task')
            item['algorithms'][algorithm] = {
                'outcome': 'complete' if complete else 'no-path',
                'points': plan['final_path'] if complete else [],
                'predicted_distance': plan['final_length'] if complete else 0,
                'source_snapshot_hash': native['source_snapshot_hash'],
                'source_query_hash': native['source_query_hash']}
        output['cases'].append(item)
    if {c['id'] for c in output['cases']} != set(CASE_IDS):
        raise ValueError('recording catalog must retain all eleven cases')
    return output


def native(binary, mods, artifact, timeout, save=None):
    return server(binary, mods, artifact, timeout, save, scenario=SCENARIO,
                  ready=lambda client: rpc(client, 'status'))


def wait_terminal(client, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = rpc(client, 'status')
        if result['phase'] in {'complete', 'failed'}:
            return result
        time.sleep(.03)
    raise ValueError('unified lab wall-time watchdog')


def verify_identity(status, case, index):
    algorithm = ('production-v1', *EXTERNAL)[index - 1] if case['domain'] == 'static' else 'production-v1'
    if status.get('case_id') != case['id'] or status.get('domain') != case['domain'] \
            or type(status.get('algorithm_index')) is not int or status['algorithm_index'] != index \
            or status.get('algorithm') != algorithm or status.get('child', {}).get('case_id') != case['id']:
        raise ValueError('unified case/algorithm identity differs from requested menu entry')
    return algorithm


def verify_selection(status, case, index):
    verify_identity(status, case, index)
    if status.get('phase') != 'prepared' or status.get('paused') is not True or status.get('free_mode') is not False:
        raise ValueError('selection did not pause the requested fixed case at its origin')


def verify_native(status, case, index):
    algorithm = verify_identity(status, case, index)
    if status['phase'] != 'complete':
        raise ValueError('unified lab did not complete: ' + json_text(status))
    result = status['result']
    if not isinstance(result, dict) or result.get('passed') is not True:
        raise ValueError('unified lab assertions failed: ' + json_text(result))
    assertions = result.get('assertions')
    if not isinstance(assertions, list) or not assertions or any(
            not isinstance(item, dict) or item.get('passed') is not True for item in assertions):
        raise ValueError('unified native assertions absent, malformed or failing')
    if case['domain'] == 'static':
        outcome = 'no-path' if case['id'] == 'unreachable-box' else 'arrived'
        native = result.get('native', {})
        if result.get('case_id') != case['id'] or result.get('algorithm') != algorithm \
                or native.get('outcome') != outcome or 'guard' in str(native.get('reason', '')):
            raise ValueError('unified native static identity or terminal differs')
    elif result.get('id') != case['id'] or result.get('terminal_state') not in {'arrived', 'rejected', 'replan-required'} \
            or 'guard' in str(result.get('reason', '')):
        raise ValueError('unified native domain identity or terminal differs')


def build(root, binary, package, artifact, reference_report, timeout):
    package.mkdir(parents=True, exist_ok=False)
    copy_mods(root, package / 'mods')
    recording = references(reference_report)
    (package / 'mods/scv-control-testkit/unified/reference_paths.lua').write_text(lua_module(recording), encoding='utf-8')
    with native(binary, package / 'mods', artifact / 'author', timeout) as (client, data):
        initial = rpc(client, 'status')
        if initial['case_count'] != 56 or initial['reference_case_count'] != 11 or not initial['paused']:
            raise ValueError('unified lab startup catalog differs')
        saved = rpc(client, 'save', name='SCV-Unified-Test-Lab')
        path = relative_file(data / 'saves', saved['filename'])
        wait_save(path, timeout)
        (package / 'saves').mkdir()
        shutil.copy2(path, package / 'saves/SCV-Unified-Test-Lab.zip')
    manual_profile(package, binary, 'saves/SCV-Unified-Test-Lab.zip')
    (package / 'open-lab.cmd').write_text('@echo off\npwsh -NoProfile -File "%~dp0open-save.ps1"\n', encoding='ascii')
    (package / 'OPEN-MAPS.txt').write_text(
        'One save: 56 shared test scenes. Open open-save.ps1 manually.\n'
        'Left panel: choose case/algorithm, select, preview, run, reset.\n'
        'Free mode attaches your character: right-click moves, Shift+right-click queues, S stops.\n'
        'Free mode uses production planner only. Gate/belt/domain features remain fixed experiments.\n'
        'External algorithms are recorded reference replays, not a live Python service.\n'
        'Reload/reset creates shared fixture geometry; this interactive sandbox does not replace source ZIP eval.\n', encoding='utf-8')
    manifest = {'schema_version': 1, 'protocol': PROTOCOL, 'cases': 56, 'static_cases': 11,
                'reference_report': str(reference_report), 'reference_hash': content_hash(recording),
                'save_file': 'saves/SCV-Unified-Test-Lab.zip',
                'save_sha256': sha256(package / 'saves/SCV-Unified-Test-Lab.zip'),
                'mods_sha256': mod_fingerprint(package / 'mods')}
    (package / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    return manifest


def test(binary, package, artifact, timeout):
    manifest = read_json(package / 'manifest.json')
    save = relative_file(package, manifest['save_file'])
    if sha256(save) != manifest['save_sha256']:
        raise ValueError('unified save changed')
    if mod_fingerprint(package / 'mods') != manifest['mods_sha256']:
        raise ValueError('unified packaged mods changed; build a fresh package')
    results = []
    with native(binary, package / 'mods', artifact / 'reloaded', timeout, save) as (client, data):
        catalog = rpc(client, 'catalog')['cases']
        if len(catalog) != 56 or len({c['id'] for c in catalog}) != 56:
            raise ValueError('unified scene denominator differs')
        # Every scene selectable/resettable inside this one loaded save.
        for entry in catalog:
            value = rpc(client, 'select', id=entry['id'], algorithm_index=1)
            verify_selection(value, entry, 1)
        results.append({'name': 'all-56-scenes-selectable-in-one-save', 'passed': True})
        # Full static menu comparison, all fixed domain execution cases.
        for entry in catalog:
            for index in (range(1, 5) if entry['domain'] == 'static' else (1,)):
                verify_selection(rpc(client, 'select', id=entry['id'], algorithm_index=index), entry, index)
                rpc(client, 'run')
                terminal = wait_terminal(client, timeout)
                verify_native(terminal, entry, index)
                results.append({'name': entry['id'] + '/' + str(index), 'passed': True,
                                'result': terminal['result']})
                print(f"[unified] PASS {len(results)-1}/89 {entry['id']} / {index}", flush=True)
        if rpc(client, 'status')['gate_surface_count'] != 0:
            raise ValueError('old gate surfaces survived subsequent native updates')
        rpc(client, 'select', id='tight-clearance-corridor')
        gui = rpc(client, 'test-ui')
        if gui.get('native_assertions_passed') is not True:
            raise ValueError('unified lifecycle assertions failed: ' + json_text(gui))
        results.append({'name': 'native-actor-lifecycle', 'passed': True, 'assertions': gui['assertions']})
        rpc(client, 'reset')
        if rpc(client, 'status')['reference_case_count'] != 11:
            raise ValueError('recordings lost after reset')
    if sha256(save) != manifest['save_sha256']:
        raise ValueError('test modified published interactive save')
    report = {'protocol': PROTOCOL, 'passed': len(results), 'failed': 0,
              'native_runs': 89, 'source_save_sha256': manifest['save_sha256'], 'results': results,
              'gui_coverage': {key: gui[key] for key in ('gui_exercised', 'gui_status', 'gui_acceptance_passed',
                                                       'right_click_movement_exercised')}}
    (artifact / 'unified-results.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    shutil.copy2(artifact / 'unified-results.json', package / 'test-results.json')
    print(f"SCV_UNIFIED_COMPLETE passed={len(results)} failed=0 native_runs=89", flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--reference-report', type=Path)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--factorio-exe')
    parser.add_argument('--test', action='store_true')
    parser.add_argument('--timeout', type=float, default=90)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be finite and positive')
    artifact = Path(tempfile.mkdtemp(prefix='scv-unified-lab-'))
    root = args.project_root.resolve()
    depot = root.parent / 'factorio-scv-testbench'
    package = args.package or depot / 'unified' / time.strftime('v1-%Y%m%d-%H%M%S')
    try:
        binary = executable_path(args.factorio_exe)
        if not package.exists():
            report = args.reference_report
            if report is None:
                reports = sorted((depot / 'comparisons').glob('*/comparison.json'), reverse=True)
                report = next((p for p in reports if read_json(p).get('matrix_passed') is True), None)
            if report is None:
                raise ValueError('run the saved solver comparison first, or pass --reference-report')
            build(root, binary, package, artifact, report, args.timeout)
        if args.test:
            test(binary, package, artifact, args.timeout)
        print('Single save: ' + str(package / 'saves/SCV-Unified-Test-Lab.zip'), flush=True)
        print('Manual launcher: ' + str(package / 'open-save.ps1'), flush=True)
        return 0
    except (OSError, ValueError, KeyError, RconError) as error:
        (artifact / 'failure.json').write_text(json.dumps({'error': str(error)}, indent=2), encoding='utf-8')
        print('SCV_UNIFIED_FAILED ' + str(error), flush=True)
        return 1
    finally:
        print('Artifacts: ' + str(artifact), flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
