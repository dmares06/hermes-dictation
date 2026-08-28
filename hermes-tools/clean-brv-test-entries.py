#!/usr/bin/env python3
"""Remove the ByteRover context-tree entries that Claude's flights/weather test
turns generated on 2026-08-28 (an explicit list — nothing else is touched),
collapse emptied directories, and repair the parent indexes and manifest.
A .tgz backup of the whole tree is written first.

Usage: python3 clean-brv-test-entries.py [--dry-run]
"""
import argparse, json, re, subprocess, time
from datetime import datetime
from pathlib import Path

TEST_ENTRIES = """
assistants/flight_search/flight_search_api_key_requirement_and_user_query.md
environment/weather/louisville_ky/current_weather_in_louisville_kentucky.md
facts/environment/weather_louisville_ky/current_weather_in_louisville_kentucky.md
facts/personal/fun_fact_about_octopuses.md
facts/personal/quick_fun_fact_octopus.md
facts/project/tool_search_response_for_search_flights.md
facts/project/tool_search_results/tool_search_results_for_search_flights.md
facts/tool_search_results/tool_search_results_for_search_flights.md
facts/weather/louisville/current_weather_in_louisville.md
facts/weather/louisville_kentucky_current_weather.md
flights/flight_search/flight_search_requirement_for_serpapi_key.md
general/animal_facts/octopus_hearts_and_circulation.md
interaction/number_sequence/turn_3_number_repetition.md
misc/number_repetition_game/turn_1_number_repetition.md
project_management/flight_search/flight_search_request_and_api_key_requirement.md
tools/flights_tool/flight_search_api_key_requirement.md
tools/integration/search_flights_tools/search_flights_tool_names.md
travel/flight_search/flight_search_request_and_tool_api_key_limitation.md
user_interaction/flight_booking/flight_search_conversation_example.md
user_requests/flights/flight_search_request_for_louisville_to_raleigh_weekend.md
weather/heat_index_and_temperature/heat_index_and_temperature_forecast.md
weather/kentucky/kentucky_current_weather_and_short_term_forecast.md
conversation/daily_status/daily_status_check_and_birthday_mention.md
environment/weather/louisville/louisville_weather_forecast.md
environment/weather/louisville_ky_current/louisville_ky_current_weather.md
environment/weather/weather_report_snapshot.md
facts/environment/current_weather_conditions_in_louisville.md
facts/fun_biology/octopus_three_hearts_fun_fact.md
facts/general/martin_luther_king_jr_speech_fact.md
facts/general_fun_facts/fun_fact_about_honey.md
""".split()

ap = argparse.ArgumentParser()
ap.add_argument('--minutes', type=int, default=130, help='window used only to REPORT other recent entries')
ap.add_argument('--dry-run', action='store_true')
args = ap.parse_args()

brv = Path.home() / '.hermes' / 'byterover'
root = brv / '.brv' / 'context-tree'
cutoff = time.time() - args.minutes * 60

candidates = [root / rel for rel in TEST_ENTRIES if (root / rel).exists()]
print(f"{len(candidates)} test-generated entries to remove:")
for f in candidates:
    print("  ", f.relative_to(root))
others = [f for f in sorted(root.rglob('*.md')) if f.name != '_index.md' and f.stat().st_mtime >= cutoff and f not in candidates]
if others:
    print(f"\nleft alone ({len(others)} other entries changed in the last {args.minutes} min — review yourself):")
    for f in others:
        print("  ", f.relative_to(root))
if args.dry_run:
    raise SystemExit("\ndry run: nothing changed")

stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
backup = brv / f'context-tree-backup-{stamp}.tgz'
subprocess.run(['tar', 'czf', str(backup), '-C', str(brv / '.brv'), 'context-tree'], check=True)
print('backup:', backup)

removed_files = []
for f in candidates:
    removed_files.append(str(f.relative_to(root))); f.unlink()

removed_dirs, changed = [], True
while changed:
    changed = False
    for d in sorted([p for p in root.rglob('*') if p.is_dir()], key=lambda p: -len(p.parts)):
        if not [e for e in d.iterdir() if e.name != '_index.md']:
            for e in d.iterdir(): e.unlink()
            d.rmdir(); removed_dirs.append(str(d.relative_to(root))); changed = True

gone = {Path(p).stem for p in removed_files} | {Path(p).name for p in removed_dirs}
fixed = 0
for idx in root.rglob('_index.md'):
    text = orig = idx.read_text(encoding='utf-8')
    m = re.search(r'^covers: \[(.*?)\]$', text, re.M)
    if m:
        kept = [c.strip() for c in m.group(1).split(',') if c.strip() and (idx.parent / c.strip()).exists()]
        text = text[:m.start()] + 'covers: [' + ', '.join(kept) + ']' + text[m.end():]
    for name in gone:
        text = re.sub(r'\n## ' + re.escape(name) + r'\n.*?(?=\n## |\Z)', '\n', text, flags=re.S)
    if text != orig:
        idx.write_text(text, encoding='utf-8'); fixed += 1

mp = root / '_manifest.json'; manifest = json.loads(mp.read_text())
before = len(manifest.get('active_context', []))
manifest['active_context'] = [e for e in manifest['active_context'] if (root / e['path']).exists()]
mp.write_text(json.dumps(manifest, indent=2))
print(f"removed {len(removed_files)} entries and {len(removed_dirs)} emptied folders; fixed {fixed} indexes; manifest {before}->{len(manifest['active_context'])}")
print("now run:  brv restart && brv query 'flights tool SERPAPI key'")
