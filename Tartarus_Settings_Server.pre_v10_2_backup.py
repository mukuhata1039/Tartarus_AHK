import json
import os
import re
import shutil
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "Tartarus_Config.tsv"
DEFAULT_CONFIG = ROOT / "Tartarus_Config.default.tsv"
BACKUP_CONFIG = ROOT / "Tartarus_Config.backup.tsv"
CURRENT_MAP_FILE = ROOT / "Tartarus_CurrentMap.txt"
LOG_DIR = ROOT / "Logs"
LOG_DIR.mkdir(exist_ok=True)
LOG = LOG_DIR / "Tartarus_Settings_Debug.log"
HOST = "127.0.0.1"
PORT = 8765

MAPS = ["Keymap 1", "Controller", "clip_studio", "aseprite", "blender"]
LAYERS = ["N", "H"]
PHYS = [f"{i:02d}" for i in range(1, 21)] + [
    "ALTBTN", "DUp", "DRight", "DDown", "DLeft", "ScrollUp", "ScrollDown"
]
DEFAULT_ACTIONS = {
    "01":"K|1","02":"K|2","03":"K|3","04":"K|4","05":"K|5",
    "06":"K|Tab","07":"K|q","08":"K|w","09":"K|e","10":"K|r",
    "11":"K|CapsLock","12":"K|a","13":"K|s","14":"K|d","15":"K|f",
    "16":"K|LShift","17":"K|z","18":"K|x","19":"K|c","20":"K|Space",
    "ALTBTN":"K|LAlt","DUp":"K|Up","DRight":"K|Right","DDown":"K|Down","DLeft":"K|Left",
    "ScrollUp":"WHEEL|1","ScrollDown":"WHEEL|-1"
}
MOUSE_ACTIONS = {"LButton","RButton","MButton","XButton1","XButton2"}
MEDIA_ACTIONS = {"Volume_Up","Volume_Down","Volume_Mute","Media_Play_Pause","Media_Next","Media_Prev","Media_Stop"}
KEY_TOKEN = re.compile(r"^[A-Za-z0-9_`~!@#$%^&*()\-=\[\]\\;',./]+$")

def log(msg):
    try:
        with LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass

def parse_tsv(path):
    result = {}
    if not path.exists():
        return result
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 4:
            continue
        m, layer, phys, action = parts
        if m in MAPS and layer in LAYERS and phys in PHYS:
            result[f"{m}|{layer}|{phys}"] = action
    return result

def valid_action(action):
    if action in ("DISABLE","HYPER"):
        return True
    if action.startswith("MAP|"):
        return action[4:] in MAPS
    if action.startswith("MOUSE|"):
        return action[6:] in MOUSE_ACTIONS
    if action.startswith("MEDIA|"):
        return action[6:] in MEDIA_ACTIONS
    if action in ("WHEEL|1","WHEEL|-1"):
        return True
    if action.startswith("K|"):
        body = action[2:]
        return bool(body) and all(KEY_TOKEN.match(x) for x in body.split("+"))
    return False

def atomic_write(mappings):
    lines = ["# Tartarus Pro mapping config v8", "# map<TAB>layer<TAB>physical<TAB>action"]
    for m in MAPS:
        for layer in LAYERS:
            for phys in PHYS:
                k = f"{m}|{layer}|{phys}"
                action = mappings.get(k)
                if action:
                    lines.append(f"{m}\t{layer}\t{phys}\t{action}")
    text = "\n".join(lines) + "\n"

    if CONFIG.exists():
        try:
            shutil.copy2(CONFIG, BACKUP_CONFIG)
        except Exception:
            pass
    tmp = CONFIG.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(tmp, CONFIG)
    log(f"saved {len(mappings)} explicit mappings")

def current_map():
    try:
        v = CURRENT_MAP_FILE.read_text(encoding="utf-8-sig").strip()
        return v if v in MAPS else ""
    except Exception:
        return ""

HTML = r'''<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tartarus Settings UI v10.1</title>
<style>
:root{
  color-scheme:dark;
  --bg:#0f1115;--panel:#171a20;--panel2:#20242c;--panel3:#272c35;
  --line:#343a46;--line2:#4a5262;--text:#f3f5f7;--muted:#959cab;
  --accent:#65a2ff;--accent2:#2b65b2;--danger:#8d4545;--good:#2c7655;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,"Yu Gothic UI",sans-serif}
header{position:sticky;top:0;z-index:5;background:rgba(15,17,21,.97);border-bottom:1px solid var(--line);padding:14px 20px}
.top{display:flex;gap:12px;align-items:center;flex-wrap:wrap;max-width:1180px;margin:auto}
h1{font-size:20px;margin:0 18px 0 0}
select,button,input{font:inherit}
select,.btn,.capturebox{background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:8px 10px}
.btn{cursor:pointer}
.btn:hover{border-color:#657089}
.btn.primary{background:#245da8;border-color:#3978cb}
.btn.danger{border-color:var(--danger)}
.spacer{flex:1}.status{font-size:13px;color:var(--muted)}
main{max-width:1180px;margin:18px auto;padding:0 18px 40px}
.notice{background:#18202b;border:1px solid #2d4057;padding:10px 12px;border-radius:8px;margin-bottom:14px;font-size:13px}
.layerbar{display:flex;gap:8px;margin:12px 0;align-items:center}
.layerbtn.active{outline:2px solid var(--accent);border-color:transparent}
.board{display:grid;grid-template-columns:minmax(0,1fr) 260px;gap:18px;align-items:start}
.keygrid{display:grid;grid-template-columns:repeat(5,minmax(100px,1fr));gap:9px}
.key{min-height:78px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:9px;padding:9px;cursor:pointer;text-align:left;transition:.08s}
.key:hover{transform:translateY(-1px);border-color:#657089}
.key .num{font-weight:700;font-size:15px}.key .action{margin-top:7px;font-size:12px;color:#bfc5d0;word-break:break-word}
.side{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px}
.side h3{font-size:14px;margin:3px 0 10px}.smallgrid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.smallgrid .key{min-height:64px}
.dpad{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin:12px 0}
.dpad .up{grid-column:2}.dpad .left{grid-column:1;grid-row:2}.dpad .right{grid-column:3;grid-row:2}.dpad .down{grid-column:2;grid-row:3}
footer{margin-top:18px;color:var(--muted);font-size:12px}

/* Razer-like assignment editor */
.modalbg{position:fixed;inset:0;background:rgba(0,0,0,.72);display:none;align-items:center;justify-content:center;z-index:20;padding:16px}
.modalbg.show{display:flex}
.modal{width:min(840px,100%);max-height:92vh;overflow:auto;background:#181b21;border:1px solid #3a414e;border-radius:12px;padding:18px}
.modal h2{margin:0 0 4px;font-size:19px}.modal .sub{color:var(--muted);font-size:12px;margin-bottom:14px}
.assignment-layout{display:grid;grid-template-columns:180px minmax(0,1fr);gap:16px;border-top:1px solid var(--line);padding-top:14px}
.types{display:flex;flex-direction:column;gap:6px}
.typebtn{text-align:left;width:100%}
.typebtn.active{background:#263750;border-color:#4f79ad;box-shadow:inset 3px 0 0 var(--accent)}
.editor{min-height:245px;background:#14171c;border:1px solid #2e343f;border-radius:9px;padding:16px}
.section-title{font-size:13px;font-weight:700;margin:0 0 9px;color:#d8dce3}
.modifiers{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px}
.modcheck{display:flex;align-items:center;gap:7px;background:var(--panel2);border:1px solid var(--line);border-radius:7px;padding:8px 12px;cursor:pointer;user-select:none}
.modcheck:hover{border-color:#657089}.modcheck input{width:17px;height:17px;accent-color:#4b8de8}
.chooser{display:grid;grid-template-columns:1fr 1.35fr;gap:12px}
.field label{display:block;font-size:12px;color:var(--muted);margin-bottom:5px}
.field select{width:100%;background:var(--panel2);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:9px 10px}
.preview{margin-top:14px;background:#202631;border:1px solid #344356;border-radius:8px;padding:11px 12px}
.preview .label{font-size:11px;color:var(--muted);margin-bottom:4px}.preview .value{font-size:16px;font-weight:650}
.capture-sep{display:flex;align-items:center;gap:9px;color:var(--muted);font-size:11px;margin:15px 0 10px}
.capture-sep:before,.capture-sep:after{content:"";height:1px;background:var(--line);flex:1}
.capturebox{width:100%;min-height:48px;display:flex;align-items:center;justify-content:center;cursor:pointer;text-align:center}
.capturebox.listening{outline:2px solid var(--accent);color:#fff}
.help{color:var(--muted);font-size:12px;margin-top:8px;line-height:1.55}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.row select{flex:1;min-width:180px}
.actions{display:flex;justify-content:flex-end;gap:8px;margin-top:18px}
#toast{position:fixed;right:18px;bottom:18px;background:#20252e;border:1px solid #455064;border-radius:8px;padding:10px 14px;display:none;z-index:30}
#toast.show{display:block}
@media(max-width:850px){
  .board{grid-template-columns:1fr}.keygrid{grid-template-columns:repeat(5,1fr)}.key{min-width:0}
  .assignment-layout{grid-template-columns:1fr}.types{display:grid;grid-template-columns:repeat(2,1fr)}
  .chooser{grid-template-columns:1fr}
}
</style>
</head>
<body><!-- TARTARUS_UI_VERSION_10_1 -->
<header><div class="top">
  <h1>Tartarus Settings <span style="font-size:11px;color:#65a2ff;font-weight:600">UI v10.1</span></h1>
  <label>Keymap <select id="mapSelect"></select></label>
  <span id="activeMap" class="status"></span>
  <div class="spacer"></div>
  <button class="btn" id="undoBtn">前回保存に戻す</button>
  <button class="btn danger" id="resetBtn">v7初期配置に戻す</button>
  <button class="btn primary" id="saveBtn">保存して即反映</button>
</div></header>

<main>
  <div class="notice">
    キーをクリックして割り当てを変更。<b>Normal / HyperShift</b> は別々に編集できる。
    キーボード割り当ては、実際にキーを押さなくてもプルダウンから選択できる。
  </div>

  <div class="layerbar">
    <button class="btn layerbtn active" data-layer="N">Normal</button>
    <button class="btn layerbtn" data-layer="H">HyperShift</button>
    <span id="dirty" class="status"></span>
  </div>

  <div class="board">
    <div id="keygrid" class="keygrid"></div>
    <div class="side">
      <h3>サイド / D-pad / ホイール</h3>
      <div class="smallgrid">
        <button class="key" data-phys="ALTBTN"></button><div></div>
        <button class="key" data-phys="ScrollUp"></button>
        <button class="key" data-phys="ScrollDown"></button>
      </div>
      <div class="dpad">
        <button class="key up" data-phys="DUp"></button>
        <button class="key left" data-phys="DLeft"></button>
        <button class="key right" data-phys="DRight"></button>
        <button class="key down" data-phys="DDown"></button>
      </div>
    </div>
  </div>

  <footer>「既定」はTartarusの素の入力へ戻す。20番からHyperShiftを外すこともできるので注意。</footer>
</main>

<div id="modalbg" class="modalbg"><div class="modal">
  <h2 id="editTitle">キー編集</h2>
  <div id="editSub" class="sub"></div>

  <div class="assignment-layout">
    <div class="types">
      <button class="btn typebtn" data-type="key">キーボード</button>
      <button class="btn typebtn" data-type="mouse">マウス</button>
      <button class="btn typebtn" data-type="map">Keymap切替</button>
      <button class="btn typebtn" data-type="hyper">HyperShift</button>
      <button class="btn typebtn" data-type="media">メディア</button>
      <button class="btn typebtn" data-type="wheel">ホイール</button>
      <button class="btn typebtn" data-type="disable">無効</button>
      <button class="btn typebtn" data-type="default">既定</button>
    </div>

    <div id="editor" class="editor"></div>
  </div>

  <div class="actions">
    <button class="btn" id="cancelEdit">キャンセル</button>
    <button class="btn primary" id="applyEdit">このキーに設定</button>
  </div>
</div></div>

<div id="toast"></div>

<script>
const MAPS=["Keymap 1","Controller","clip_studio","aseprite","blender"];
const PHYS_MAIN=Array.from({length:20},(_,i)=>String(i+1).padStart(2,"0"));
const LABELS={ALTBTN:"親指",DUp:"D-pad ↑",DRight:"D-pad →",DDown:"D-pad ↓",DLeft:"D-pad ←",ScrollUp:"ホイール ↑",ScrollDown:"ホイール ↓"};

/* Dropdown catalog. Values are AutoHotkey key names understood by GetKeySC(). */
const KEY_CATALOG=[
  {id:"letters",name:"英字",keys:"abcdefghijklmnopqrstuvwxyz".split("").map(x=>[x,x.toUpperCase()])},
  {id:"numbers",name:"数字キー",keys:Array.from({length:10},(_,i)=>[String(i),String(i)])},
  {id:"function",name:"ファンクションキー",keys:Array.from({length:24},(_,i)=>[`F${i+1}`,`F${i+1}`])},
  {id:"navigation",name:"移動・編集",keys:[
    ["Esc","Esc"],["Tab","Tab"],["Enter","Enter"],["Space","Space"],["Backspace","Backspace"],
    ["Insert","Insert"],["Delete","Delete"],["Home","Home"],["End","End"],["PgUp","Page Up"],["PgDn","Page Down"],
    ["Up","↑ 上"],["Down","↓ 下"],["Left","← 左"],["Right","→ 右"]
  ]},
  {id:"numpad",name:"テンキー",keys:[
    ["Numpad0","Num 0"],["Numpad1","Num 1"],["Numpad2","Num 2"],["Numpad3","Num 3"],["Numpad4","Num 4"],
    ["Numpad5","Num 5"],["Numpad6","Num 6"],["Numpad7","Num 7"],["Numpad8","Num 8"],["Numpad9","Num 9"],
    ["NumpadDot","Num ."],["NumpadEnter","Num Enter"],["NumpadAdd","Num +"],["NumpadSub","Num -"],
    ["NumpadMult","Num ×"],["NumpadDiv","Num ÷"],["NumLock","Num Lock"]
  ]},
  {id:"modifiers",name:"修飾キー",keys:[
    ["LControl","左 Ctrl"],["RControl","右 Ctrl"],["LShift","左 Shift"],["RShift","右 Shift"],
    ["LAlt","左 Alt"],["RAlt","右 Alt"],["LWin","左 Win"],["RWin","右 Win"]
  ]},
  {id:"system",name:"システム・ロック",keys:[
    ["PrintScreen","Print Screen"],["ScrollLock","Scroll Lock"],["Pause","Pause / Break"],
    ["CapsLock","Caps Lock"],["AppsKey","Menu / Apps"]
  ]}
];

const MODS=[
  {id:"modCtrl",token:"LControl",label:"Ctrl"},
  {id:"modShift",token:"LShift",label:"Shift"},
  {id:"modAlt",token:"LAlt",label:"Alt"},
  {id:"modWin",token:"LWin",label:"Win"}
];

let data=null,mappings={},original={},currentLayer="N";
let editPhys=null,editType="key",editAction="",listening=false,modifierOnly=null;
let keyboardSource="builder";

const $=id=>document.getElementById(id);
const mapSelect=$("mapSelect"),keygrid=$("keygrid"),dirty=$("dirty"),
      activeMap=$("activeMap"),modalbg=$("modalbg"),editor=$("editor");

function keyId(p){return `${mapSelect.value}|${currentLayer}|${p}`}
function explicit(p){return mappings[keyId(p)]??null}

function prettyKey(k){
  const t={
    LControl:"Ctrl",RControl:"R-Ctrl",LShift:"Shift",RShift:"R-Shift",
    LAlt:"Alt",RAlt:"R-Alt",LWin:"Win",RWin:"R-Win",
    NumpadDot:"Num .",NumpadEnter:"Num Enter",NumpadAdd:"Num +",
    NumpadSub:"Num -",NumpadMult:"Num ×",NumpadDiv:"Num ÷",
    NumLock:"Num Lock",PgUp:"Page Up",PgDn:"Page Down",AppsKey:"Menu"
  };
  return t[k]||(k.length===1?k.toUpperCase():k);
}
function prettyResolved(a){
  if(a==="DISABLE")return"無効";
  if(a==="HYPER")return"HyperShift";
  if(a.startsWith("K|"))return a.slice(2).split("+").map(prettyKey).join(" + ");
  if(a.startsWith("MAP|"))return"Keymap → "+a.slice(4);
  if(a.startsWith("MOUSE|"))return({LButton:"左クリック",RButton:"右クリック",MButton:"中クリック",XButton1:"X1",XButton2:"X2"}[a.slice(6)]||a);
  if(a.startsWith("MEDIA|"))return({Volume_Up:"音量 +",Volume_Down:"音量 -",Volume_Mute:"ミュート",Media_Play_Pause:"再生 / 停止",Media_Next:"次へ",Media_Prev:"前へ",Media_Stop:"停止"}[a.slice(6)]||a);
  if(a==="WHEEL|1")return"ホイール ↑";
  if(a==="WHEEL|-1")return"ホイール ↓";
  return a;
}
function pretty(a,p){return a===null?`既定 → ${prettyResolved(data.defaults[p]||"DISABLE")}`:prettyResolved(a)}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}

function render(){
  keygrid.innerHTML="";
  PHYS_MAIN.forEach(p=>{
    const b=document.createElement("button");
    b.className="key";
    b.innerHTML=`<div class="num">${p}</div><div class="action">${esc(pretty(explicit(p),p))}</div>`;
    b.onclick=()=>openEditor(p);
    keygrid.appendChild(b);
  });
  document.querySelectorAll(".side .key").forEach(b=>{
    const p=b.dataset.phys;
    b.innerHTML=`<div class="num">${LABELS[p]}</div><div class="action">${esc(pretty(explicit(p),p))}</div>`;
    b.onclick=()=>openEditor(p);
  });
  dirty.textContent=JSON.stringify(mappings)===JSON.stringify(original)?"":"未保存の変更あり";
}

function actionType(a){
  if(a===null)return"default";
  if(a==="DISABLE")return"disable";
  if(a==="HYPER")return"hyper";
  if(a.startsWith("K|"))return"key";
  if(a.startsWith("MOUSE|"))return"mouse";
  if(a.startsWith("MAP|"))return"map";
  if(a.startsWith("MEDIA|"))return"media";
  if(a.startsWith("WHEEL|"))return"wheel";
  return"key";
}

function openEditor(p){
  editPhys=p;
  const a=explicit(p);
  editAction=a??"";
  editType=actionType(a);
  $("editTitle").textContent=`${LABELS[p]||p} の割り当て`;
  $("editSub").textContent=`${mapSelect.value} / ${currentLayer==="N"?"Normal":"HyperShift"} / 現在: ${pretty(a,p)}`;
  modalbg.classList.add("show");
  chooseType(editType);
}

function findCatalogForKey(key){
  for(const cat of KEY_CATALOG){
    if(cat.keys.some(x=>x[0]===key))return cat.id;
  }
  return KEY_CATALOG[0].id;
}

function parseKeyboardAction(action){
  const result={mods:new Set(),main:"a"};
  if(!action.startsWith("K|"))return result;

  const parts=action.slice(2).split("+").filter(Boolean);
  const checkboxTokens=new Set(MODS.map(m=>m.token));
  const nonMods=parts.filter(x=>!checkboxTokens.has(x));

  if(nonMods.length){
    result.main=nonMods[nonMods.length-1];
    parts.forEach(x=>{if(checkboxTokens.has(x))result.mods.add(x)});
  }else if(parts.length){
    /* A single modifier such as K|LShift must remain a main key, not become an empty shortcut. */
    result.main=parts[parts.length-1];
    parts.slice(0,-1).forEach(x=>{if(checkboxTokens.has(x))result.mods.add(x)});
  }
  return result;
}

function buildKeyboardAction(){
  const parts=[];
  MODS.forEach(m=>{const el=$(m.id);if(el&&el.checked)parts.push(m.token)});
  const main=$("mainKey")?.value;
  if(!main)return"";
  parts.push(main);
  return"K|"+parts.join("+");
}

function updateKeyboardPreview(){
  const a=buildKeyboardAction();
  if(a){
    editAction=a;
    keyboardSource="builder";
    $("keyPreview").textContent=prettyResolved(a);
  }
}

function populateMainKey(categoryId,selectedKey){
  const cat=KEY_CATALOG.find(c=>c.id===categoryId)||KEY_CATALOG[0];
  const sel=$("mainKey");
  sel.innerHTML=cat.keys.map(([v,label])=>`<option value="${esc(v)}">${esc(label)}</option>`).join("");
  if(cat.keys.some(x=>x[0]===selectedKey))sel.value=selectedKey;
  sel.onchange=updateKeyboardPreview;
}

function renderKeyboardEditor(){
  keyboardSource="builder";
  const parsed=parseKeyboardAction(editAction);
  const category=findCatalogForKey(parsed.main);

  editor.innerHTML=`
    <div class="section-title">修飾キー</div>
    <div class="modifiers">
      ${MODS.map(m=>`<label class="modcheck"><input id="${m.id}" type="checkbox"> ${m.label}</label>`).join("")}
    </div>

    <div class="section-title">メインキー</div>
    <div class="chooser">
      <div class="field">
        <label>分類</label>
        <select id="keyCategory">
          ${KEY_CATALOG.map(c=>`<option value="${c.id}">${c.name}</option>`).join("")}
        </select>
      </div>
      <div class="field">
        <label>キー</label>
        <select id="mainKey"></select>
      </div>
    </div>

    <div class="preview">
      <div class="label">割り当て結果</div>
      <div id="keyPreview" class="value"></div>
    </div>

    <div class="capture-sep">または実際のキーボードから記録</div>
    <div id="capture" tabindex="0" class="capturebox">クリックしてキー入力を記録</div>
    <div class="help">
      小型キーボードに存在しないキーは上のプルダウンから選べる。<br>
      例: <b>Ctrl</b> と <b>Shift</b> にチェック → 分類「英字」→ <b>Z</b> で <b>Ctrl + Shift + Z</b>。
    </div>`;

  $("keyCategory").value=category;
  populateMainKey(category,parsed.main);
  $("mainKey").value=parsed.main;

  MODS.forEach(m=>{
    $(m.id).checked=parsed.mods.has(m.token);
    $(m.id).onchange=updateKeyboardPreview;
  });

  $("keyCategory").onchange=()=>{
    populateMainKey($("keyCategory").value,null);
    updateKeyboardPreview();
  };

  $("mainKey").onchange=updateKeyboardPreview;

  $("capture").onclick=()=>{
    listening=true;modifierOnly=null;keyboardSource="capture";
    $("capture").classList.add("listening");
    $("capture").textContent="入力待ち…";
    $("capture").focus();
  };

  updateKeyboardPreview();
}

function chooseType(t){
  editType=t;
  document.querySelectorAll(".typebtn").forEach(x=>x.classList.toggle("active",x.dataset.type===t));
  listening=false;modifierOnly=null;

  if(t==="key"){
    renderKeyboardEditor();
  }else if(t==="mouse"){
    editor.innerHTML=`<div class="section-title">マウスボタン</div><div class="row"><select id="choice">
      <option value="LButton">左クリック</option><option value="RButton">右クリック</option>
      <option value="MButton">中クリック</option><option value="XButton1">X1</option><option value="XButton2">X2</option>
    </select></div>`;
    if(editAction.startsWith("MOUSE|"))$("choice").value=editAction.slice(6);
  }else if(t==="map"){
    editor.innerHTML=`<div class="section-title">切替先Keymap</div><div class="row"><select id="choice">${MAPS.map(m=>`<option>${m}</option>`).join("")}</select></div>`;
    if(editAction.startsWith("MAP|"))$("choice").value=editAction.slice(4);
  }else if(t==="media"){
    editor.innerHTML=`<div class="section-title">メディア操作</div><div class="row"><select id="choice">
      <option value="Volume_Up">音量 +</option><option value="Volume_Down">音量 -</option><option value="Volume_Mute">ミュート</option>
      <option value="Media_Play_Pause">再生 / 停止</option><option value="Media_Next">次へ</option>
      <option value="Media_Prev">前へ</option><option value="Media_Stop">停止</option>
    </select></div>`;
    if(editAction.startsWith("MEDIA|"))$("choice").value=editAction.slice(6);
  }else if(t==="wheel"){
    editor.innerHTML=`<div class="section-title">ホイール出力</div><div class="row"><select id="choice">
      <option value="1">ホイール ↑</option><option value="-1">ホイール ↓</option>
    </select></div>`;
    if(editAction.startsWith("WHEEL|"))$("choice").value=editAction.slice(6);
  }else if(t==="hyper"){
    editor.innerHTML=`<div class="section-title">HyperShift</div><div>この物理キーを押している間、HyperShiftレイヤーを有効にする。</div>`;
  }else if(t==="disable"){
    editor.innerHTML=`<div class="section-title">無効</div><div>このキーからは何も出力しない。</div>`;
  }else if(t==="default"){
    editor.innerHTML=`<div class="section-title">既定入力</div><div>Tartarusの素の入力へ戻す。<br><b>${esc(prettyResolved(data.defaults[editPhys]||"DISABLE"))}</b></div>`;
  }
}
document.querySelectorAll(".typebtn").forEach(b=>b.onclick=()=>chooseType(b.dataset.type));

function codeToAhk(e){
  const c=e.code,t={
    Escape:"Esc",Tab:"Tab",CapsLock:"CapsLock",Backspace:"Backspace",Enter:"Enter",Space:"Space",
    Insert:"Insert",Delete:"Delete",Home:"Home",End:"End",PageUp:"PgUp",PageDown:"PgDn",
    ArrowUp:"Up",ArrowDown:"Down",ArrowLeft:"Left",ArrowRight:"Right",PrintScreen:"PrintScreen",
    ScrollLock:"ScrollLock",Pause:"Pause",ContextMenu:"AppsKey",
    ControlLeft:"LControl",ControlRight:"RControl",ShiftLeft:"LShift",ShiftRight:"RShift",
    AltLeft:"LAlt",AltRight:"RAlt",MetaLeft:"LWin",MetaRight:"RWin",
    NumpadDecimal:"NumpadDot",NumpadEnter:"NumpadEnter",NumpadAdd:"NumpadAdd",
    NumpadSubtract:"NumpadSub",NumpadMultiply:"NumpadMult",NumpadDivide:"NumpadDiv",
    NumLock:"NumLock"
  };
  if(t[c])return t[c];
  if(/^Key[A-Z]$/.test(c))return c.slice(3).toLowerCase();
  if(/^Digit[0-9]$/.test(c))return c.slice(5);
  if(/^F([1-9]|1[0-9]|2[0-4])$/.test(c))return c;
  if(/^Numpad[0-9]$/.test(c))return c;
  return null;
}
function isMod(c){return /^(Control|Shift|Alt|Meta)(Left|Right)$/.test(c)}
function modsFromEvent(e,main){
  const r=[];
  if(e.ctrlKey && main!=="LControl" && main!=="RControl")r.push("LControl");
  if(e.shiftKey && main!=="LShift" && main!=="RShift")r.push("LShift");
  if(e.altKey && main!=="LAlt" && main!=="RAlt")r.push("LAlt");
  if(e.metaKey && main!=="LWin" && main!=="RWin")r.push("LWin");
  return r;
}

window.addEventListener("keydown",e=>{
  if(!listening)return;
  e.preventDefault();e.stopPropagation();
  const main=codeToAhk(e),cap=$("capture");
  if(!main){cap.textContent="このキーは未対応。プルダウンから選択して。";return}
  if(isMod(e.code)){modifierOnly=main;cap.textContent=prettyKey(main)+" …";return}
  const p=modsFromEvent(e,main);p.push(main);
  editAction="K|"+p.join("+");
  keyboardSource="capture";
  cap.textContent="記録: "+prettyResolved(editAction);
  cap.classList.remove("listening");
  $("keyPreview").textContent=prettyResolved(editAction);
  listening=false;
},{capture:true});

window.addEventListener("keyup",e=>{
  if(!listening||!modifierOnly||!isMod(e.code))return;
  e.preventDefault();e.stopPropagation();
  editAction="K|"+modifierOnly;
  keyboardSource="capture";
  const cap=$("capture");
  cap.textContent="記録: "+prettyResolved(editAction);
  cap.classList.remove("listening");
  $("keyPreview").textContent=prettyResolved(editAction);
  listening=false;modifierOnly=null;
},{capture:true});

$("applyEdit").onclick=()=>{
  const k=keyId(editPhys);

  if(editType==="default")delete mappings[k];
  else if(editType==="disable")mappings[k]="DISABLE";
  else if(editType==="hyper")mappings[k]="HYPER";
  else if(editType==="mouse")mappings[k]="MOUSE|"+$("choice").value;
  else if(editType==="map")mappings[k]="MAP|"+$("choice").value;
  else if(editType==="media")mappings[k]="MEDIA|"+$("choice").value;
  else if(editType==="wheel")mappings[k]="WHEEL|"+$("choice").value;
  else if(editType==="key"){
    if(keyboardSource==="builder")editAction=buildKeyboardAction();
    if(!editAction.startsWith("K|")){toast("キーを選択してから設定して",true);return}
    mappings[k]=editAction;
  }

  modalbg.classList.remove("show");
  render();
};

$("cancelEdit").onclick=()=>modalbg.classList.remove("show");
modalbg.onclick=e=>{if(e.target===modalbg)modalbg.classList.remove("show")};

document.querySelectorAll(".layerbtn").forEach(b=>b.onclick=()=>{
  currentLayer=b.dataset.layer;
  document.querySelectorAll(".layerbtn").forEach(x=>x.classList.toggle("active",x===b));
  render();
});
mapSelect.onchange=render;

$("saveBtn").onclick=async()=>{
  try{
    const r=await fetch("/api/save",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({mappings})});
    const j=await r.json();
    if(!r.ok)throw new Error(j.error||"save failed");
    original=structuredClone(mappings);render();
    toast("保存した。約0.3秒以内に反映。");
  }catch(e){toast("保存失敗: "+e.message,true)}
};

$("resetBtn").onclick=async()=>{
  if(!confirm("v7で使っていた初期配置へ戻す？"))return;
  const r=await fetch("/api/reset",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"});
  if(r.ok){await load();toast("v7初期配置に戻した")}else toast("リセット失敗",true);
};

$("undoBtn").onclick=async()=>{
  const r=await fetch("/api/restore",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"});
  const j=await r.json();
  if(r.ok){await load();toast("前回保存へ戻した")}else toast(j.error||"戻せなかった",true);
};

function toast(msg,bad=false){
  const t=$("toast");t.textContent=msg;t.style.borderColor=bad?"#a64b4b":"#455064";
  t.classList.add("show");setTimeout(()=>t.classList.remove("show"),2200);
}

async function load(){
  const r=await fetch("/api/config");
  data=await r.json();
  mappings=structuredClone(data.mappings);
  original=structuredClone(data.mappings);
  mapSelect.innerHTML=MAPS.map(m=>`<option>${m}</option>`).join("");
  if(data.current_map&&MAPS.includes(data.current_map))mapSelect.value=data.current_map;
  activeMap.textContent=data.current_map?`現在使用中: ${data.current_map}`:"";
  render();
}
load().catch(e=>toast("設定読み込み失敗: "+e.message,true));
</script>
</body>
</html>'''

class Handler(BaseHTTPRequestHandler):
    server_version = "TartarusSettings/10.1"
    def log_message(self, fmt, *args):
        log(fmt % args)
    def json_out(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(body))); self.send_header("Cache-Control","no-store"); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/":
            body=HTML.encode("utf-8"); self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(body))); self.send_header("Cache-Control","no-store"); self.end_headers(); self.wfile.write(body)
        elif p == "/api/config":
            self.json_out(200,{"maps":MAPS,"phys":PHYS,"mappings":parse_tsv(CONFIG),"defaults":DEFAULT_ACTIONS,"current_map":current_map()})
        elif p == "/api/version":
            self.json_out(200,{"ui_version":"10.1","marker":"TARTARUS_UI_VERSION_10_1"})
        else:
            self.send_error(404)
    def same_origin(self):
        o=self.headers.get("Origin")
        return (not o) or o in (f"http://{HOST}:{PORT}",f"http://localhost:{PORT}")
    def body_json(self):
        n=int(self.headers.get("Content-Length","0"))
        if n > 1024*1024: raise ValueError("request too large")
        return json.loads(self.rfile.read(n).decode("utf-8"))
    def do_POST(self):
        if not self.same_origin():
            self.json_out(403,{"error":"origin rejected"}); return
        p=urlparse(self.path).path
        try: payload=self.body_json()
        except Exception as e: self.json_out(400,{"error":f"bad json: {e}"}); return
        if p == "/api/save":
            incoming=payload.get("mappings")
            if not isinstance(incoming,dict): self.json_out(400,{"error":"mappings must be an object"}); return
            clean={}
            for k,a in incoming.items():
                if not isinstance(k,str) or not isinstance(a,str): self.json_out(400,{"error":"invalid mapping entry"}); return
                parts=k.split("|")
                if len(parts)!=3: self.json_out(400,{"error":f"invalid mapping id: {k}"}); return
                m,l,ph=parts
                if m not in MAPS or l not in LAYERS or ph not in PHYS or not valid_action(a):
                    self.json_out(400,{"error":f"invalid mapping: {k} -> {a}"}); return
                clean[k]=a
            atomic_write(clean); self.json_out(200,{"ok":True,"count":len(clean)}); return
        if p == "/api/reset":
            if not DEFAULT_CONFIG.exists(): self.json_out(500,{"error":"default config missing"}); return
            if CONFIG.exists():
                try: shutil.copy2(CONFIG,BACKUP_CONFIG)
                except Exception: pass
            tmp=CONFIG.with_suffix(".tmp"); shutil.copyfile(DEFAULT_CONFIG,tmp); os.replace(tmp,CONFIG); log("reset to defaults"); self.json_out(200,{"ok":True}); return
        if p == "/api/restore":
            if not BACKUP_CONFIG.exists(): self.json_out(404,{"error":"前回保存のバックアップがまだない"}); return
            current=CONFIG.read_bytes() if CONFIG.exists() else None
            tmp=CONFIG.with_suffix(".tmp"); shutil.copyfile(BACKUP_CONFIG,tmp); os.replace(tmp,CONFIG)
            if current is not None: BACKUP_CONFIG.write_bytes(current)
            log("restored previous save"); self.json_out(200,{"ok":True}); return
        self.send_error(404)

def main():
    LOG.write_text("",encoding="utf-8"); log(f"server start http://{HOST}:{PORT}")
    httpd=ThreadingHTTPServer((HOST,PORT),Handler)
    try: httpd.serve_forever(poll_interval=0.25)
    finally: httpd.server_close(); log("server stop")

if __name__=="__main__":
    main()
