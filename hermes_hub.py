"""Local-only Hermes Hub web UI and HTTP API."""

from __future__ import annotations

import json
import logging
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from hermes_store import LocalStore


log = logging.getLogger("hermes.hub")


class HubServer:
    """Serve the Hub on loopback and open it in the user's browser."""

    def __init__(self, store: LocalStore, get_settings=None, update_settings=None):
        self.store = store
        self.get_settings = get_settings or (lambda: {})
        self.update_settings = update_settings or (lambda updates: {})
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None
        self.url: str | None = None

    def start(self) -> str:
        if self.httpd is not None:
            return self.url or ""
        server = self

        class RequestHandler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                log.debug("Hub HTTP: " + format, *args)

            def _send(self, status, payload, content_type="application/json; charset=utf-8"):
                if isinstance(payload, str):
                    body = payload.encode("utf-8")
                else:
                    body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def _json_body(self):
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length > 1_000_000:
                        raise ValueError("request body too large")
                    return json.loads(self.rfile.read(length) or b"{}")
                except (ValueError, TypeError, json.JSONDecodeError) as exc:
                    raise ValueError("invalid JSON body") from exc

            def do_GET(self):
                parsed = urlparse(self.path)
                path = parsed.path
                query = parse_qs(parsed.query)
                try:
                    if path == "/":
                        return self._send(200, HUB_HTML, "text/html; charset=utf-8")
                    if path == "/api/stats":
                        return self._send(200, server.store.stats())
                    if path == "/api/transcripts":
                        term = query.get("q", [""])[0]
                        return self._send(200, server.store.list_transcripts(term, limit=200))
                    if path == "/api/snippets":
                        return self._send(200, server.store.list_snippets())
                    if path == "/api/notes":
                        return self._send(200, server.store.list_notes())
                    if path == "/api/settings":
                        return self._send(200, server.get_settings())
                    return self._send(404, {"error": "not found"})
                except Exception as exc:
                    log.exception("Hub GET failed")
                    return self._send(500, {"error": str(exc)})

            def do_POST(self):
                path = urlparse(self.path).path
                try:
                    body = self._json_body()
                    if path == "/api/snippets":
                        snippet_id = server.store.save_snippet(
                            body.get("trigger", ""), body.get("value", ""), body.get("action", "insert"), body.get("id")
                        )
                        return self._send(200, {"id": snippet_id})
                    if path == "/api/notes":
                        note_id = server.store.save_note(body.get("title", ""), body.get("body", ""), body.get("id"))
                        return self._send(200, {"id": note_id})
                    if path == "/api/settings":
                        return self._send(200, server.update_settings(body) or {})
                    return self._send(404, {"error": "not found"})
                except ValueError as exc:
                    return self._send(400, {"error": str(exc)})
                except Exception as exc:
                    log.exception("Hub POST failed")
                    return self._send(500, {"error": str(exc)})

            def do_DELETE(self):
                path = urlparse(self.path).path.rstrip("/")
                try:
                    item_id = int(path.rsplit("/", 1)[1])
                    if path.startswith("/api/transcripts/"):
                        server.store.delete_transcript(item_id)
                    elif path.startswith("/api/snippets/"):
                        server.store.delete_snippet(item_id)
                    elif path.startswith("/api/notes/"):
                        server.store.delete_note(item_id)
                    else:
                        return self._send(404, {"error": "not found"})
                    return self._send(200, {"ok": True})
                except (ValueError, IndexError) as exc:
                    return self._send(400, {"error": str(exc)})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), RequestHandler)
        self.httpd.daemon_threads = True
        host, port = self.httpd.server_address
        self.url = f"http://{host}:{port}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, name="hermes-hub", daemon=True)
        self.thread.start()
        log.info("Hermes Hub listening at %s", self.url)
        return self.url

    def open(self) -> str:
        url = self.start()
        webbrowser.open(url)
        return url

    def stop(self):
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None
            self.url = None


HUB_HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hermes Hub</title>
<style>
:root{--ink:#242126;--muted:#7e7880;--line:#e9e4dc;--paper:#fbfaf7;--card:#fff;--teal:#216d6d;--teal-soft:#dcefed;--lilac:#e9dcfa;--peach:#f6e1d4;--shadow:0 14px 36px rgba(50,36,29,.06)}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",sans-serif}button,input,textarea,select{font:inherit}button{cursor:pointer;border:0} .shell{display:flex;min-height:100vh}.sidebar{width:238px;padding:30px 18px 24px;border-right:1px solid var(--line);background:#f5f2ed;display:flex;flex-direction:column}.brand{font-size:24px;font-weight:750;letter-spacing:-.06em;margin:0 16px 35px}.brand span{color:var(--teal)}.nav{display:grid;gap:6px}.nav button{background:transparent;color:#5b5559;text-align:left;padding:12px 15px;border-radius:12px;font-weight:600}.nav button:hover{background:#ebe7e0}.nav button.active{background:#e8e3db;color:var(--ink)}.side-foot{margin-top:auto;color:var(--muted);font-size:12px;padding:16px}.main{max-width:1280px;flex:1;padding:38px clamp(28px,5vw,78px) 60px}.topline{display:flex;justify-content:space-between;align-items:start;gap:20px;margin-bottom:32px}.eyebrow{text-transform:uppercase;letter-spacing:.14em;font-size:11px;color:var(--teal);font-weight:750}.page-title{font-size:37px;letter-spacing:-.055em;margin:4px 0 5px}.subtitle{color:var(--muted);margin:0}.status{background:var(--teal-soft);color:var(--teal);border-radius:999px;padding:8px 13px;font-size:12px;font-weight:700}.view{display:none}.view.active{display:block}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin-bottom:18px}.metric,.panel{background:var(--card);border:1px solid var(--line);border-radius:18px;box-shadow:var(--shadow)}.metric{padding:22px 22px 20px;min-height:132px}.metric .label{color:var(--muted);font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.1em}.metric .value{font-size:35px;letter-spacing:-.06em;font-weight:720;margin-top:12px}.metric .detail{color:var(--muted);font-size:12px;margin-top:2px}.grid-2{display:grid;grid-template-columns:1.25fr .75fr;gap:18px}.panel{padding:25px}.panel h2{font-size:17px;letter-spacing:-.025em;margin:0}.panel-head{display:flex;justify-content:space-between;gap:15px;align-items:center;margin-bottom:20px}.muted{color:var(--muted)}.activity{height:188px;display:flex;align-items:end;gap:8px;padding:15px 6px 7px;border-bottom:1px solid var(--line)}.bar-wrap{flex:1;height:100%;display:flex;align-items:end;justify-content:center;position:relative}.bar{width:100%;max-width:24px;min-height:3px;background:linear-gradient(#73bcb3,var(--teal));border-radius:7px 7px 2px 2px}.bar-wrap small{position:absolute;bottom:-24px;font-size:10px;color:var(--muted)}.transcript{padding:14px 0;border-bottom:1px solid var(--line);display:flex;gap:15px}.transcript:last-child{border-bottom:0}.time{font-size:11px;color:var(--muted);white-space:nowrap;width:58px;padding-top:2px}.transcript p{margin:0;line-height:1.45}.empty{padding:30px 0;color:var(--muted);text-align:center}.toolbar{display:flex;gap:10px;margin-bottom:18px}.input,.select,.textarea{width:100%;border:1px solid var(--line);background:#fff;border-radius:11px;padding:11px 13px;color:var(--ink);outline:0}.input:focus,.select:focus,.textarea:focus{border-color:#8fc8c1;box-shadow:0 0 0 3px #dff2ef}.textarea{min-height:150px;resize:vertical}.primary{background:var(--ink);color:white;border-radius:11px;padding:11px 17px;font-weight:700;white-space:nowrap}.soft{background:#f0ece6;color:var(--ink);border-radius:10px;padding:9px 13px;font-weight:650}.danger{background:transparent;color:#ae5a54;padding:7px}.item-list{display:grid;gap:10px}.list-card{background:white;border:1px solid var(--line);border-radius:14px;padding:16px 18px;display:flex;align-items:center;justify-content:space-between;gap:18px}.list-card strong{display:block}.list-card .value{color:var(--muted);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:700px}.pill{display:inline-block;background:var(--lilac);border-radius:99px;padding:4px 9px;font-size:11px;margin-left:8px}.form-grid{display:grid;grid-template-columns:1fr 2fr auto;gap:10px;align-items:end}.form-label{font-size:12px;color:var(--muted);font-weight:700;display:block;margin:0 0 6px}.note-layout{display:grid;grid-template-columns:270px 1fr;gap:18px}.notes-list{display:grid;gap:8px;align-content:start}.note-link{padding:13px;border:1px solid var(--line);background:white;border-radius:12px;text-align:left}.note-link.active{border-color:#8fc8c1;background:var(--teal-soft)}.note-link strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.note-link small{color:var(--muted)}.editor{display:grid;gap:12px}.settings{max-width:760px;display:grid;gap:12px}.setting{display:flex;justify-content:space-between;align-items:center;gap:25px;padding:18px 20px;background:#fff;border:1px solid var(--line);border-radius:14px}.setting h3{margin:0;font-size:15px}.setting p{margin:3px 0 0;color:var(--muted);font-size:13px}.setting .select{width:190px}.toggle{width:45px;height:26px;border-radius:99px;background:#cfc9c1;position:relative}.toggle:after{content:"";position:absolute;width:20px;height:20px;top:3px;left:3px;background:#fff;border-radius:50%;transition:.15s}.toggle.on{background:var(--teal)}.toggle.on:after{left:22px}.notice{position:fixed;right:22px;bottom:22px;background:var(--ink);color:white;padding:12px 16px;border-radius:11px;box-shadow:var(--shadow);opacity:0;transform:translateY(10px);transition:.2s;pointer-events:none}.notice.show{opacity:1;transform:translateY(0)}@media(max-width:900px){.sidebar{width:180px}.metrics{grid-template-columns:repeat(2,1fr)}.grid-2,.note-layout{grid-template-columns:1fr}.form-grid{grid-template-columns:1fr}.main{padding:28px 24px}}@media(max-width:640px){.shell{display:block}.sidebar{width:auto;border-right:0;border-bottom:1px solid var(--line);padding:16px}.brand{margin:0 5px 12px}.nav{display:flex;overflow:auto}.nav button{white-space:nowrap}.side-foot{display:none}.main{padding:24px 16px}.metrics{gap:9px}.metric{padding:16px}.metric .value{font-size:28px}.topline{display:block}.status{display:inline-block;margin-top:13px}}
</style></head>
<body><div class="shell"><aside class="sidebar"><div class="brand">Hermes <span>Hub</span></div><nav class="nav"><button data-view="dashboard" class="active">◒&nbsp; Dashboard</button><button data-view="history">▤&nbsp; History</button><button data-view="snippets">⌘&nbsp; Snippets</button><button data-view="scratchpad">□&nbsp; Scratchpad</button><button data-view="settings">⚙&nbsp; Settings</button></nav><div class="side-foot">Local by default · no account<br>Everything stays on this Mac.</div></aside><main class="main"><div class="topline"><div><div class="eyebrow">Private dictation workspace</div><h1 class="page-title" id="page-title">Your speaking, at a glance</h1><p class="subtitle" id="page-subtitle">A local record of the words you have spoken with Hermes.</p></div><div class="status" id="hub-status">● Local only</div></div>
<section id="dashboard" class="view active"><div class="metrics"><div class="metric"><div class="label">Words this month</div><div class="value" id="month-words">0</div><div class="detail">spoken with Hermes</div></div><div class="metric"><div class="label">Sessions</div><div class="value" id="month-sessions">0</div><div class="detail">dictation sessions this month</div></div><div class="metric"><div class="label">Average WPM</div><div class="value" id="month-wpm">—</div><div class="detail">based on recorded duration</div></div><div class="metric"><div class="label">All-time words</div><div class="value" id="total-words">0</div><div class="detail">stored locally</div></div></div><div class="grid-2"><div class="panel"><div class="panel-head"><h2>Recent activity</h2><span class="muted">last 30 days</span></div><div class="activity" id="activity"></div></div><div class="panel"><div class="panel-head"><h2>Latest words</h2><button class="soft" data-go="history">See all</button></div><div id="latest"></div></div></div></section>
<section id="history" class="view"><div class="panel"><div class="panel-head"><div><h2>Transcript history</h2><span class="muted">Your cleaned dictation is saved here locally.</span></div></div><div class="toolbar"><input class="input" id="history-search" placeholder="Search your transcripts…"><button class="soft" id="refresh-history">Refresh</button></div><div id="history-list"></div></div></section>
<section id="snippets" class="view"><div class="panel"><div class="panel-head"><div><h2>Snippets</h2><span class="muted">Say an exact phrase to insert text or open a page.</span></div></div><form id="snippet-form"><div class="form-grid"><label><span class="form-label">Trigger phrase</span><input class="input" id="snippet-trigger" placeholder="my LinkedIn" required></label><label><span class="form-label">Insert text or URL</span><input class="input" id="snippet-value" placeholder="https://www.linkedin.com/in/you/" required></label><label><span class="form-label">Action</span><select class="select" id="snippet-action"><option value="open">Open URL</option><option value="insert">Insert text</option></select></label><button class="primary" type="submit">Save</button></div></form><div class="item-list" id="snippet-list" style="margin-top:20px"></div></div></section>
<section id="scratchpad" class="view"><div class="panel"><div class="panel-head"><div><h2>Scratchpad</h2><span class="muted">A quiet place for ideas, lists, and rough thoughts.</span></div><button class="primary" id="new-note">New note</button></div><div class="note-layout"><div class="notes-list" id="notes-list"></div><form class="editor" id="note-form"><input type="hidden" id="note-id"><input class="input" id="note-title" placeholder="Note title"><textarea class="textarea" id="note-body" placeholder="Start talking or type an idea…"></textarea><button class="primary" type="submit">Save note</button></form></div></div></section>
<section id="settings" class="view"><div class="panel"><div class="panel-head"><div><h2>Settings</h2><span class="muted">Tune the shortcut and transcription behavior.</span></div><button class="primary" id="save-settings">Save settings</button></div><div class="settings"><div class="setting"><div><h3>Dictation shortcut</h3><p>Hold this key while you speak.</p></div><select class="select" id="setting-hotkey"><option value="fn">Fn / Globe</option><option value="alt_r">Right Option</option><option value="alt_l">Left Option</option><option value="ctrl_r">Right Control</option><option value="caps_lock">Caps Lock</option><option value="f5">F5</option><option value="f6">F6</option></select></div><div class="setting"><div><h3>Whisper model</h3><p>Larger models can be more accurate but take longer.</p></div><select class="select" id="setting-model"><option>tiny</option><option>base</option><option>small</option><option>medium</option><option>large-v3</option></select></div><div class="setting"><div><h3>Transcription mode</h3><p>Fast favors turnaround; Quality favors difficult audio.</p></div><select class="select" id="setting-speed"><option value="quality">Quality</option><option value="fast">Fast</option></select></div><div class="setting"><div><h3>Remove hesitation words</h3><p>Clean out “um,” “uh,” and boundary fillers.</p></div><button type="button" class="toggle" id="setting-fillers" aria-label="Toggle filler removal"></button></div><div class="setting"><div><h3>Automatic punctuation</h3><p>Capitalize and finish dictated thoughts naturally.</p></div><button type="button" class="toggle" id="setting-punctuation"></button></div><div class="setting"><div><h3>Pause dictation</h3><p>Temporarily stop the hotkey from listening.</p></div><button type="button" class="toggle" id="setting-paused"></button></div></div></div></section>
</main></div><div class="notice" id="notice"></div>
<script>
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const titles={dashboard:['Your speaking, at a glance','A local record of the words you have spoken with Hermes.'],history:['Transcript history','Find, review, and remove anything Hermes has logged.'],snippets:['Shortcuts for the things you repeat','Say a phrase to open a page or insert text instantly.'],scratchpad:['A space for unfinished thoughts','Keep ideas close without sending them anywhere.'],settings:['Make Hermes yours','Shortcut, speed, and cleanup controls for local dictation.']};
let notes=[];
function notify(message){const n=$('#notice');n.textContent=message;n.classList.add('show');setTimeout(()=>n.classList.remove('show'),2200)}
async function api(path,options={}){const r=await fetch(path,options);const data=await r.json();if(!r.ok)throw Error(data.error||'Something went wrong');return data}
function showView(name){$$('.view').forEach(x=>x.classList.toggle('active',x.id===name));$$('.nav button').forEach(x=>x.classList.toggle('active',x.dataset.view===name));$('#page-title').textContent=titles[name][0];$('#page-subtitle').textContent=titles[name][1];if(name==='dashboard')loadDashboard();if(name==='history')loadHistory();if(name==='snippets')loadSnippets();if(name==='scratchpad')loadNotes();if(name==='settings')loadSettings()}
$$('.nav button').forEach(b=>b.onclick=()=>showView(b.dataset.view));$$('[data-go]').forEach(b=>b.onclick=()=>showView(b.dataset.go));
function fmt(n){return Number(n||0).toLocaleString()};function time(s){return new Date(s).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'})};
function transcriptRow(t){return `<div class="transcript"><div class="time">${time(t.created_at)}</div><p>${esc(t.text)}</p></div>`};function esc(s){return String(s||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]))}
async function loadDashboard(){const [stats,items]=await Promise.all([api('/api/stats'),api('/api/transcripts?limit=8')]);const m=stats.month||{},t=stats.total||{};$('#month-words').textContent=fmt(m.words);$('#month-sessions').textContent=fmt(m.sessions);$('#month-wpm').textContent=m.average_wpm?Math.round(m.average_wpm):'—';$('#total-words').textContent=fmt(t.words);const days=[...stats.daily].reverse();const max=Math.max(1,...days.map(x=>x.words));$('#activity').innerHTML=days.length?days.map(x=>`<div class="bar-wrap"><div class="bar" style="height:${Math.max(4,x.words/max*100)}%" title="${fmt(x.words)} words"></div><small>${x.day.slice(5)}</small></div>`).join(''):'<div class="empty">Start dictating to see your rhythm.</div>';$('#latest').innerHTML=items.length?items.slice(0,4).map(transcriptRow).join(''):'<div class="empty">Your first transcript will appear here.</div>'}
async function loadHistory(){const q=encodeURIComponent($('#history-search').value||'');const items=await api('/api/transcripts?q='+q);$('#history-list').innerHTML=items.length?items.map(t=>`<div class="list-card"><div><strong>${esc(t.text)}</strong><span class="muted">${new Date(t.created_at).toLocaleString()} · ${fmt(t.word_count)} words</span></div><button class="danger" onclick="removeItem('transcripts',${t.id},loadHistory)">Delete</button></div>`).join(''):'<div class="empty">No transcripts yet.</div>'}
async function loadSnippets(){const items=await api('/api/snippets');$('#snippet-list').innerHTML=items.length?items.map(x=>`<div class="list-card"><div><strong>“${esc(x.trigger)}” <span class="pill">${x.action==='open'?'opens':'inserts'}</span></strong><div class="value">${esc(x.value)}</div></div><button class="danger" onclick="removeItem('snippets',${x.id},loadSnippets)">Delete</button></div>`).join(''):'<div class="empty">No snippets yet. Try “my LinkedIn”.</div>'}
async function removeItem(kind,id,refresh){await api('/api/'+kind+'/'+id,{method:'DELETE'});notify('Deleted');refresh()}
$('#snippet-form').onsubmit=async e=>{e.preventDefault();await api('/api/snippets',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({trigger:$('#snippet-trigger').value,value:$('#snippet-value').value,action:$('#snippet-action').value})});e.target.reset();notify('Snippet saved');loadSnippets()};
function loadNotes(){api('/api/notes').then(items=>{notes=items;$('#notes-list').innerHTML=items.length?items.map((n,i)=>`<button type="button" class="note-link ${i===0?'active':''}" onclick="editNote(${n.id})"><strong>${esc(n.title||'Untitled note')}</strong><small>${new Date(n.updated_at).toLocaleDateString()}</small></button>`).join(''):'<div class="empty">No notes yet.</div>';if(items.length)editNote(items[0].id);else clearNote()})}
function editNote(id){const n=notes.find(x=>x.id===id);if(!n)return;$('#note-id').value=n.id;$('#note-title').value=n.title;$('#note-body').value=n.body;$$('.note-link').forEach(x=>x.classList.remove('active'));event&&event.currentTarget&&event.currentTarget.classList.add('active')}
function clearNote(){$('#note-id').value='';$('#note-title').value='';$('#note-body').value=''}
$('#new-note').onclick=()=>{clearNote();$('#note-title').focus()};$('#note-form').onsubmit=async e=>{e.preventDefault();await api('/api/notes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:$('#note-id').value||null,title:$('#note-title').value,body:$('#note-body').value})});notify('Note saved');loadNotes()};
function toggle(id,value){$(id).classList.toggle('on',!!value);$(id).dataset.value=!!value}
async function loadSettings(){const s=await api('/api/settings');$('#setting-hotkey').value=s.hotkey||'fn';$('#setting-model').value=s.model_size||'small';$('#setting-speed').value=s.speed_mode||'quality';toggle('#setting-fillers',s.remove_fillers);toggle('#setting-punctuation',s.auto_punctuate);toggle('#setting-paused',s.paused);}
$$('.toggle').forEach(x=>x.onclick=()=>x.classList.toggle('on'));$('#save-settings').onclick=async()=>{const body={hotkey:$('#setting-hotkey').value,model_size:$('#setting-model').value,speed_mode:$('#setting-speed').value,remove_fillers:$('#setting-fillers').classList.contains('on'),auto_punctuate:$('#setting-punctuation').classList.contains('on'),paused:$('#setting-paused').classList.contains('on')};await api('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});notify('Settings saved')};$('#history-search').oninput=()=>{clearTimeout(window.searchTimer);window.searchTimer=setTimeout(loadHistory,220)};$('#refresh-history').onclick=loadHistory;
loadDashboard();
</script></body></html>'''
