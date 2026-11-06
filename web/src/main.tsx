import { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { MediaPlayer, MediaProvider } from '@vidstack/react';
import '@vidstack/react/player/styles/default/theme.css';
import '@vidstack/react/player/styles/default/layouts/video.css';
import { defaultLayoutIcons, DefaultVideoLayout } from '@vidstack/react/player/layouts/default';
import './style.css';

type Item = { id:string; type:string; title:string; originalName?:string; position?:number; mediaKind?:string; mimeType?:string; extension?:string; sizeBytes?:number; streamUrl?:string; contentUrl?:string; children?:Item[]; subtitles?:Item[]; assets?:Item[]; sections?:Item[]; lessons?:Item[] };
type Course = { id:string; title:string; originalName?:string };
type ScanProgress = { phase:string; entriesVisited:number; currentDirectory:string; currentOperation?:string; directoriesRead?:number; activeDirectoryReads?:number; activeMetadataReads?:number; elapsedMs:number; enumerationMs:number; metadataMs:number; persistenceMs:number };
type IndexStatus = { state?:string; itemCount?:number; lastScanStartedAt?:string|null; lastScanCompletedAt?:string|null; lastScanError?:string|null; progress?:ScanProgress };
const api = async <T,>(url:string, init?:RequestInit):Promise<T> => { const res=await fetch(url,init); if(!res.ok) throw new Error(`${res.status} ${res.statusText}: ${await res.text()}`); return res.json() as Promise<T>; };

function App(){
 const [courses,setCourses]=useState<Course[]>([]); const [tree,setTree]=useState<Item|null>(null); const [selected,setSelected]=useState<Item|null>(null); const [status,setStatus]=useState<IndexStatus>({}); const [error,setError]=useState(''); const [json,setJson]=useState(''); const [busy,setBusy]=useState(false); const [scanPending,setScanPending]=useState(false); const scanPendingRef=useRef(false); const scanBaseline=useRef<unknown>(null);
 const statusRef=useRef<IndexStatus>({}); const treeRef=useRef<Item|null>(null); const refreshInFlight=useRef(false); const lastLibraryRefresh=useRef(0);
 const refresh=async(forceLibrary=true)=>{
  if(refreshInFlight.current)return;
  refreshInFlight.current=true;
  try{
   const s=await api<IndexStatus>('/api/v1/index/status');
   const finished=statusRef.current.state==='scanning'&&s.state!=='scanning';
   statusRef.current=s;setStatus(s);
   if(scanPendingRef.current&&(s.state==='scanning'||s.lastScanStartedAt!==scanBaseline.current)){scanPendingRef.current=false;setScanPending(false);}
   if(forceLibrary||finished||Date.now()-lastLibraryRefresh.current>=8000){
    const libs=await api<{id:string;name:string}[]>('/api/v1/libraries');const lib=libs[0];if(!lib)throw new Error('No library configured');
    const all:Course[]=[];let cursor:string|null=null;
    do{const page: {items:Course[];nextCursor?:string|null}=await api(`/api/v1/libraries/${lib.id}/courses${cursor?`?cursor=${cursor}`:''}`);all.push(...page.items||[]);cursor=page.nextCursor??null;}while(cursor);
    setCourses(all);lastLibraryRefresh.current=Date.now();
    const current=treeRef.current;
    if(current&&(s.state==='scanning'||finished)){
     const value=await api<Item>(`/api/v1/courses/${current.id}/tree`);
     if(treeRef.current?.id===current.id){treeRef.current=value;setTree(value);setJson(JSON.stringify(value,null,2));}
    }
   }
   setError('');
  }catch(e){setError(String(e))}finally{refreshInFlight.current=false}
 };
 useEffect(()=>{
  let stopped=false;let timer:ReturnType<typeof setTimeout>;
  const poll=async()=>{await refresh(false);if(!stopped)timer=setTimeout(()=>void poll(),statusRef.current.state==='scanning'||scanPendingRef.current?1000:8000)};
  void poll();return()=>{stopped=true;clearTimeout(timer)};
 },[status.state,scanPending]);
 const openCourse=async(c:Course)=>{try{setError('');const value=await api<Item>(`/api/v1/courses/${c.id}/tree`);treeRef.current=value;setTree(value);setSelected(null);setJson(JSON.stringify(value,null,2))}catch(e){setError(String(e))}};
 const scan=async()=>{if(status.state==='scanning'||busy||scanPending)return;setBusy(true);setError('');scanBaseline.current=status.lastScanStartedAt??null;try{await api('/api/v1/index/scan',{method:'POST'});scanPendingRef.current=true;setScanPending(true);await refresh()}catch(e){setError(String(e))}finally{setBusy(false)}};
 const select=(item:Item)=>{setSelected(item);setJson(JSON.stringify(item,null,2))};
 const lessons=(node:Item|null):Item[]=>node?[...(node.lessons||[]),...(node.sections||[]).flatMap(lessons),...(node.assets||[]).flatMap(assetLessons)]:[];
 const displayTree=tree?effectiveRoot(tree):null;
 const count=lessons(displayTree).filter(x=>x.type==='lesson').length;
 return <div className="app"><header><a className="brand" href="/">Medina</a><div className="header-actions"><span className={`status ${status.state==='idle'?'':'busy'}`}>{String(status.state||'loading')}{status.state==='scanning'?` · ${String(status.progress?.entriesVisited??0)} visited`:''}</span><button disabled={busy||scanPending||status.state==='scanning'} onClick={()=>void scan()}>{busy||scanPending||status.state==='scanning'?'Scanning…':'Rescan'}</button><button className="secondary" onClick={()=>void refresh()}>Refresh</button></div></header>
 {error&&<div className="error"><span>{error}</span><button onClick={()=>setError('')}>Dismiss</button></div>}
 <div className="layout"><aside className="sidebar"><div className="side-heading">LIBRARY <span>{courses.length} courses</span></div>{courses.length===0?<p className="muted">No indexed courses. Run a scan.</p>:courses.map(c=><button key={c.id} className={`course ${tree?.id===c.id?'active':''}`} title={c.originalName||c.title} onClick={()=>void openCourse(c)}>{cleanCourseName(c.title)}</button>)}{displayTree&&<><div className="side-heading content-heading">{cleanCourseName(displayTree.title).toUpperCase()}</div><Tree item={displayTree} onSelect={select} selected={selected?.id||''}/></>}</aside>
 <main className="main"><ScanStatus status={status}/>{!displayTree?<div className="placeholder"><h2>Choose a course</h2><p>Select a course to browse lessons and files.</p><small>Index status: {String(status.state||'loading')} · {status.state==='scanning'?`${String(status.progress?.entriesVisited??0)} entries visited · ${String(status.itemCount??0)} available in index`:`Last scan: ${String(status.lastScanCompletedAt||'not yet scanned')}`}</small></div>:!selected?<><div className="main-heading"><div><h1>{cleanCourseName(displayTree.title)}</h1><p>{count} lessons · select a lesson or asset from the library tree</p></div><details className="json"><summary>Course JSON</summary><pre>{json}</pre></details></div><div className="placeholder compact"><p>Select an item in the left panel to play or preview it.</p></div></>:selected.type==='lesson'?<Lesson item={selected}/>:<AssetPreview key={selected.id} item={selected}/>}
 </main></div><footer>Local development client · unauthenticated</footer></div>
}
function cleanCourseName(raw:string){
 let s=raw.trim();
 while(s.startsWith('[')&&s.includes(']'))s=s.slice(s.indexOf(']')+1).trim();
 for(const p of ['udemy -','udemy–','udemy —','udemy:','[udemy]','udemy']){if(s.toLowerCase().startsWith(p)){const next=s.slice(p.length).replace(/^[\s\-–—:]+/,'');if(next)s=next;}}
 while(s.endsWith(']')&&s.lastIndexOf('[')>0){const next=s.slice(0,s.lastIndexOf('[')).trim();if(!next)break;s=next;}
 return s||raw;
}
function effectiveRoot(root:Item):Item{
 if(root.type!=='course')return root;
 const courseTokens=cleanCourseName(root.originalName||root.title).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
 const isWrapper=(sec:Item):boolean=>{
  const children=sec.sections||[],direct=sec.lessons||[],name=(sec.originalName||sec.title).trim();
  if(!direct.length&&children.length>1)return true;
  if(!direct.length&&children.length===1&&isWrapper(children[0]))return true;
  if(!/^\d+[\s\-_.)]/.test(name)&&(children.length||direct.length)){
   const tokens=cleanCourseName(name).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean),joined=tokens.join(''),courseJoined=courseTokens.join('');
   if(['course','courses','content','coursecontent','videos','video','lectures','lessons','main','files','coursefiles'].includes(joined)||joined&&joined===courseJoined)return true;
   if(tokens.length>=2&&courseTokens.length>=2&&joined.length>=10&&(courseJoined.includes(joined)||joined.includes(courseJoined)))return true;
   if(children.length>1&&children.filter(c=>/^\d+[\s\-_.)]/.test((c.originalName||c.title).trim())).length>=2)return true;
  }
  return false;
 };
 let cur=root;
 while(!(cur.lessons||[]).length&&(cur.sections||[]).length===1&&isWrapper(cur.sections![0])){
  const only=cur.sections![0];
  cur={...cur,sections:only.sections,lessons:only.lessons,assets:[...(only.assets||[]),...(cur.assets||[])],subtitles:[...(only.subtitles||[]),...(cur.subtitles||[])]};
 }
 return cur;
}
function formatDuration(ms:number){const seconds=Math.floor(ms/1000);return seconds<60?`${seconds}s`:`${Math.floor(seconds/60)}m ${seconds%60}s`}
function ScanStatus({status}:{status:IndexStatus}){
 const p=status.progress;const running=status.state==='scanning';
 if(!running&&!p&&!status.lastScanError)return null;
 const phases:Record<string,string>={preparing:'Preparing index',enumerating:'Discovering entries',canonicalizing:'Organizing courses and sidecars',persisting:'Saving changes',publishing:'Reconciling removed entries',complete:'Scan complete',failed:'Scan failed'};
 const operations:Record<string,string>={queued:'Waiting for a directory worker',listing:'Listing directory',metadata:'Reading entry metadata',ready:'Directory ready',visiting:'Processing discovered entries'};
 return <section className={`scan-panel ${status.state==='failed'?'failed':''}`} aria-label="Index scan progress">
  <div className="scan-heading"><strong>{p?phases[p.phase]||p.phase:running?'Preparing scan':'Scan failed'}</strong><span>{p?formatDuration(p.elapsedMs):''}</span></div>
  {running&&<progress aria-label="Scan in progress — total entry count is not yet known"/>}
  <div className="scan-stats"><span><b>{p?.entriesVisited??0}</b> entries visited</span><span><b>{status.itemCount??0}</b> indexed entries{running?' (includes previous scan)':''}</span>{p&&p.elapsedMs>0&&<span>{(p.entriesVisited/(p.elapsedMs/1000)).toFixed(1)} entries/s</span>}</div>
  {running&&p?.currentOperation&&<div className="scan-operation">{operations[p.currentOperation]||p.currentOperation} · {p.activeDirectoryReads??0} directory reads / {p.activeMetadataReads??0} metadata reads active</div>}
  {p?.directoriesRead!==undefined&&<div className="scan-operation">{p.directoriesRead} directories listed</div>}
  {running&&p?.currentDirectory&&<div className="scan-directory" title={p.currentDirectory}>Directory: <code>{p.currentDirectory==='.'?'Library root':p.currentDirectory}</code></div>}
  {p&&<details className="scan-timings"><summary>Work timings (parallel operations overlap)</summary><span>Directory listings: {formatDuration(p.enumerationMs)} · Metadata reads: {formatDuration(p.metadataMs)} · Persistence: {formatDuration(p.persistenceMs)}</span></details>}
  {status.lastScanError&&<p className="scan-error">{status.lastScanError}</p>}
 </section>
}
function assetLessons(item:Item):Item[]{return item.type==='asset_directory'?(item.children||[]).flatMap(assetLessons):item.type==='lesson'?[item]:[]}
function Tree({item,onSelect,selected}:{item:Item;onSelect:(x:Item)=>void;selected:string}){return <div className="tree">{(item.sections||[]).map(section=><div className="tree-group" key={section.id}><div className="section-label">{section.title}</div>{(section.lessons||[]).map(lesson=><button key={lesson.id} className={`tree-item ${selected===lesson.id?'selected':''}`} onClick={()=>onSelect(lesson)}><span className="item-icon">▶</span>{lesson.title}</button>)}<AssetTree items={section.assets||[]} onSelect={onSelect} selected={selected}/>{(section.sections||[]).map(n=><Tree key={n.id} item={n} onSelect={onSelect} selected={selected}/>)}</div>)}{(item.lessons||[]).map(lesson=><button key={lesson.id} className={`tree-item ${selected===lesson.id?'selected':''}`} onClick={()=>onSelect(lesson)}><span className="item-icon">▶</span>{lesson.title}</button>)}<AssetTree items={item.assets||[]} onSelect={onSelect} selected={selected}/></div>}
function AssetTree({items,onSelect,selected}:{items:Item[];onSelect:(x:Item)=>void;selected:string}){return <>{items.map(item=>item.type==='asset_directory'?<div className="asset-directory-row" key={item.id}><details className="asset-directory"><summary className="tree-item folder">▸ {item.title}/</summary><div className="nested"><AssetTree items={item.children||[]} onSelect={onSelect} selected={selected}/></div></details><a className="zip-link" href={`/api/v1/assets/${item.id}/archive.zip`} title={`Download ${item.title} as ZIP`}>ZIP</a></div>:item.type==='asset'?<button key={item.id} className={`tree-item asset ${selected===item.id?'selected':''}`} onClick={()=>onSelect(item)}><span className="item-icon">{fileGlyph(item)}</span>{item.originalName||item.title}</button>:null)}</>}
function fileGlyph(item:Item){const ext=(item.extension||'').toLowerCase();if(ext==='pdf')return 'PDF';if(['png','jpg','jpeg','gif','webp','bmp'].includes(ext))return 'IMG';if(['go','ts','js','py','rs','md','json','yaml','yml','toml','css','html','sql','sh'].includes(ext))return 'TXT';return 'FILE'}
function Lesson({item}:{item:Item}){return <article className="viewer"><div className="viewer-heading"><div><div className="kind">{item.mediaKind||'media'}</div><h2>{item.title}</h2><code>{item.streamUrl}</code></div><a className="link" href={item.streamUrl} target="_blank" rel="noreferrer">Open source</a></div><div className="player"><MediaPlayer title={item.title} src={item.streamUrl||''} viewType={item.mediaKind==='audio'?'audio':'video'} crossOrigin playsInline><MediaProvider/><DefaultVideoLayout icons={defaultLayoutIcons}/></MediaPlayer></div><p className="note">Original media · browser codec support required</p></article>}
function AssetPreview({item}:{item:Item}){const [text,setText]=useState('');const [error,setError]=useState('');const [loading,setLoading]=useState(false);const ext=(item.extension||'').toLowerCase();const mime=(item.mimeType||'').toLowerCase();const code=['go','rs','py','js','jsx','ts','tsx','json','yaml','yml','toml','xml','csv','sh','sql','css','md'].includes(ext);const image=mime.startsWith('image/')&&ext!=='svg';const pdf=mime==='application/pdf'||ext==='pdf';const previewURL=`/api/v1/assets/${item.id}/preview`;const downloadURL=`/api/v1/assets/${item.id}/download`;
 useEffect(()=>{if(!code)return;let cancelled=false;setLoading(true);fetch(previewURL).then(async r=>{if(!r.ok)throw new Error(`${r.status} ${r.statusText}`);return r.text()}).then(t=>{if(!cancelled)setText(t)}).catch(e=>{if(!cancelled)setError(String(e))}).finally(()=>{if(!cancelled)setLoading(false)});return()=>{cancelled=true}},[previewURL,code]);
 return <article className="viewer"><div className="viewer-heading"><div><div className="kind">{item.mimeType||'file'}{item.sizeBytes?` · ${formatSize(item.sizeBytes)}`:''}</div><h2>{item.originalName||item.title}</h2><code>{previewURL}</code></div><div className="file-actions"><a className="link" href={previewURL} target="_blank" rel="noreferrer">Open preview</a><a className="link" href={downloadURL}>Download</a></div></div><div className={`asset-preview ${pdf?'pdf':image?'image':code?'text':'unsupported'}`}>{pdf?<iframe title={`Preview ${item.title}`} src={previewURL}/>:image?<img src={previewURL} alt={item.title}/>:code?loading?<p>Loading preview…</p>:error?<p className="error-text">{error}</p>:<pre>{text}</pre>:<div><p>No inline preview for this file type.</p><a className="link" href={downloadURL}>Download original file</a></div>}</div></article>
}
function formatSize(size:number){if(size<1024)return `${size} B`;if(size<1024*1024)return `${(size/1024).toFixed(1)} KB`;return `${(size/(1024*1024)).toFixed(1)} MB`}
createRoot(document.getElementById('root')!).render(<App/>);
