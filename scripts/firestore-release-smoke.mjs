import {readFileSync,writeFileSync,unlinkSync,mkdirSync,realpathSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {randomUUID,createHash} from 'node:crypto';
import {dirname,join,resolve,basename} from 'node:path';
import {fileURLToPath} from 'node:url';

// Primary contracts: https://firebase.google.com/docs/firestore/use-rest-api
// https://firebase.google.com/docs/reference/rest/auth
// https://firebase.google.com/docs/firestore/reference/rest/v1/StructuredQuery
// User ID tokens exercise Security Rules. Operator OAuth tokens are never used.
const mode=process.argv[2];
if(!['--emulator','--production'].includes(mode)) throw new Error('Explicit --emulator or --production required');
const live=mode==='--production';
const repo=realpathSync(resolve(dirname(fileURLToPath(import.meta.url)),'..'));
const options={};
for(let i=3;i<process.argv.length;i+=2) {
  const key=process.argv[i],value=process.argv[i+1];
  if(!['--output','--release-evidence','--app-config'].includes(key)||!value||options[key]) throw new Error('Invalid or duplicate argument');
  options[key]=resolve(value);
}
if(!options['--output']||(live&&(!options['--release-evidence']||!options['--app-config']))) throw new Error('Usage: --emulator --output NEW_PRIVATE_DIR, or --production --output NEW_PRIVATE_DIR --release-evidence RELEASE_JSON --app-config APP_PLIST');
if(!live&&(options['--release-evidence']||options['--app-config'])) throw new Error('Production inputs cannot be used in emulator mode');
const project=live?'augmentmereality':'demo-amr-release-checks';
const output=join(realpathSync(dirname(options['--output'])),basename(options['--output']));
let insideGit=false;
try {insideGit=execFileSync('git',['rev-parse','--is-inside-work-tree'],{cwd:dirname(output),encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim()==='true';} catch {}
if(insideGit) throw new Error('Private cleanup credentials require an output directory outside Git checkouts');
mkdirSync(output,{mode:0o700});
const evidence={schemaVersion:1,project,mode,runnerSHA256:createHash('sha256').update(readFileSync(fileURLToPath(import.meta.url))).digest('hex'),startedAt:new Date().toISOString(),checks:[],cleanup:[],sources:['https://firebase.google.com/docs/firestore/use-rest-api','https://firebase.google.com/docs/reference/rest/auth','https://firebase.google.com/docs/firestore/reference/rest/v1/StructuredQuery']};
const ledger={accounts:{},drops:[],reactions:[]};
const privatePath=join(output,'private-cleanup-ledger.json');
const persist=()=>writeFileSync(privatePath,JSON.stringify(ledger,null,2),{mode:0o600});
let config;
let stage='configuration';
const base=(live?'https://firestore.googleapis.com':'http://127.0.0.1:8191')+'/v1/projects/'+project+'/databases/(default)/documents';
const s=value=>({stringValue:value});
const eq=(field,value)=>({fieldFilter:{field:{fieldPath:field},op:'EQUAL',value:s(value)}});
const name=id=>'projects/'+project+'/databases/(default)/documents/drops/'+id;
const ids={private:randomUUID().toUpperCase(),link:randomUUID().toUpperCase(),public:randomUUID().toUpperCase(),viewer:randomUUID().toUpperCase(),orphan:randomUUID().toUpperCase(),missing:randomUUID().toUpperCase()};
const allowedDrops=new Set(Object.values(ids));
function allowedPath(path) {
  const parts=path.split('/');
  return parts[0]==='drops'&&allowedDrops.has(parts[1])&&(parts.length===2||(parts.length===4&&parts[2]==='reactions'&&ledger.reactions.some(r=>r.path===path)));
}
async function request(url,method,body,token) {
  const response=await fetch(url,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{}),...(live?{'X-Ios-Bundle-Identifier':config.BUNDLE_ID}:{})},...(body?{body:JSON.stringify(body)}:{}),redirect:'error',signal:AbortSignal.timeout(20000)});
  const raw=await response.text();
  const data=raw?JSON.parse(raw):{};
  const error=Array.isArray(data)?data.find(item=>item.error)?.error:data.error;
  return {status:error?.code??response.status,error:error?.status??null,data};
}
async function auth(method,body) {
  return request('https://identitytoolkit.googleapis.com/v1/accounts:'+method+'?key='+encodeURIComponent(config.API_KEY),'POST',body);
}
function emulatedUser() {
  const uid='amr-release-'+randomUUID();
  const header=Buffer.from(JSON.stringify({alg:'none',typ:'JWT'})).toString('base64url');
  const payload=Buffer.from(JSON.stringify({sub:uid,user_id:uid,aud:project,iss:'https://securetoken.google.com/'+project,iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600,firebase:{sign_in_provider:'anonymous',identities:{}}})).toString('base64url');
  return {uid,token:header+'.'+payload+'.'};
}
async function newAccount(role) {
  if(!live) ledger.accounts[role]=emulatedUser();
  else {
    const result=await auth('signUp',{returnSecureToken:true});
    if(result.status!==200||!result.data.idToken||!result.data.localId) throw new Error('Anonymous sign-in did not succeed');
    const claims=JSON.parse(Buffer.from(result.data.idToken.split('.')[1],'base64url').toString());
    if(claims.aud!==project||claims.iss!=='https://securetoken.google.com/'+project||claims.sub!==result.data.localId||claims.firebase?.sign_in_provider!=='anonymous') throw new Error('Test identity target mismatch');
    ledger.accounts[role]={uid:result.data.localId,token:result.data.idToken,refreshToken:result.data.refreshToken};
  }
  persist();
}
function record(label,result,expected,verify=()=>true) {
  const passed=result.status===expected&&verify(result.data)&&(!(expected===403)||result.error==='PERMISSION_DENIED');
  evidence.checks.push({label,status:result.status,expected,passed});
  console.log(JSON.stringify({label,status:result.status,passed}));
  if(!passed) throw new Error('Check failed: '+label);
  return result.data;
}
async function doc(method,path,role,body,query='') {
  if(!allowedPath(path)) throw new Error('Path outside this run refused');
  return request(base+'/'+path+query,method,body,ledger.accounts[role]?.token);
}
function dropFields(id,role,visibility) {
  // Mirror FirebaseDropStore.CloudDrop: GeoDrop is nested, while rule-facing
  // ownership/visibility and geohash remain on the envelope.
  const geo={id:s(id),ownerUid:s(ledger.accounts[role].uid),visibility:s(visibility),content:s('text3D'),message:s('AMR issue 2 controlled release check'),latitude:{doubleValue:0},longitude:{doubleValue:0},heightAboveGround:{doubleValue:1},scale:{doubleValue:1},colorHex:s('#34C759'),createdBy:s('Release verification'),createdAt:{timestampValue:new Date().toISOString()},anchorMode:s('ground')};
  return {drop:{mapValue:{fields:geo}},ownerUid:s(ledger.accounts[role].uid),visibility:s(visibility),geohash:s('s00000000'),releaseVerification:s(ids.orphan)};
}
async function createDrop(id,role,visibility) {
  ledger.drops.push({id,role,confirmed:false}); persist();
  const result=await request(base+'/drops?documentId='+id,'POST',{fields:dropFields(id,role,visibility)},ledger.accounts[role].token);
  record('create '+visibility+' drop '+role,result,200,data=>data.name===name(id));
  ledger.drops.at(-1).confirmed=true;persist();
}
async function query(role,filter,limit) {
  if(limit!==0&&!(filter?.fieldFilter?.field.fieldPath==='ownerUid'&&filter.fieldFilter.value.stringValue===ledger.accounts[role]?.uid)) throw new Error('Query could read non-test documents');
  const result=await request(base+':runQuery','POST',{structuredQuery:{from:[{collectionId:'drops'}],...(filter?{where:filter}:{}),limit}},ledger.accounts[role]?.token);
  if(Array.isArray(result.data)) for(const item of result.data) if(item.document&&!ledger.drops.some(d=>item.document.name===name(d.id))) throw new Error('Unexpected document in isolated-owner query');
  return result;
}
async function reaction(parent,role,emoji,overrides={}) {
  const id=randomUUID().toUpperCase();
  const path='drops/'+parent+'/reactions/'+id;
  ledger.reactions.push({path,role});persist();
  const fields={id:s(id),emoji:s(emoji),uid:s(ledger.accounts[role].uid),byName:s('Release verification'),at:{timestampValue:new Date().toISOString()},...overrides};
  return {path,fields,result:await doc('PATCH',path,role,{fields},'?currentDocument.exists=false')};
}
async function cleanup() {
  let clean=true;
  for(const item of [...ledger.reactions].reverse()) {
    const candidates=[item.role,...Object.keys(ledger.accounts).filter(r=>r!==item.role)];
    let removed=false;
    for(const role of candidates) {
      try {
        const existing=await doc('GET',item.path,role);
        if(existing.status===404) {removed=true;break;}
        if(existing.status!==200) continue;
        if(!Object.values(ledger.accounts).some(a=>a.uid===existing.data.fields?.uid?.stringValue)) break;
        const result=await doc('DELETE',item.path,role);
        if(result.status===200) {removed=true;break;}
      } catch {}
    }
    evidence.cleanup.push({kind:'reaction',removed}); clean&&=removed;
  }
  for(const item of [...ledger.drops].reverse()) {
    let removed=false;
    for(const role of [item.role,...Object.keys(ledger.accounts).filter(r=>r!==item.role)]) {
      try {
        const existing=await doc('GET','drops/'+item.id,role);
        if(existing.status===404) {removed=true;break;}
        if(existing.status!==200) continue;
        if(!Object.values(ledger.accounts).some(a=>a.uid===existing.data.fields?.ownerUid?.stringValue)||(!item.confirmed&&existing.data.fields?.releaseVerification?.stringValue!==ids.orphan)) break;
        if((await doc('DELETE','drops/'+item.id,role)).status===200) {removed=true;break;}
      } catch {}
    }
    evidence.cleanup.push({kind:'drop',removed});clean&&=removed;
  }
  if(clean) for(const role of Object.keys(ledger.accounts)) {
    try {
      const removed=!live||(await auth('delete',{idToken:ledger.accounts[role].token})).status===200;
      evidence.cleanup.push({kind:'anonymous-account',role,removed});clean&&=removed;
    } catch {evidence.cleanup.push({kind:'anonymous-account',role,removed:false});clean=false;}
  }
  evidence.cleanupComplete=clean;
  if(clean) {try{unlinkSync(privatePath);}catch{}}
  return clean;
}
try {
  if(live) {
    if(process.env.FIRESTORE_EMULATOR_HOST) throw new Error('Emulator environment present during live run');
    const active=JSON.parse(readFileSync(options['--release-evidence'],'utf8'));
    const hash=createHash('sha256').update(readFileSync(join(repo,'web/firestore.rules'))).digest('hex');
    if(active.target.projectId!==project||!active.candidate.matchesActiveSource||active.candidate.sha256!==hash||hash!=='cd613a6be99c86e071cf4782d4e170731363b0a9496b4d781007e12d02c457b6'||Date.now()-Date.parse(active.checkedAt)>3600000) throw new Error('Fresh reviewed active release evidence required');
    evidence.activeRuleset=active.release.rulesetName;evidence.candidateSHA256=hash;
    const raw=execFileSync('python3',['-c','import json,plistlib,sys;d=plistlib.load(open(sys.argv[1],"rb"));print(json.dumps({k:d[k] for k in ["API_KEY","PROJECT_ID","BUNDLE_ID","GCM_SENDER_ID"]}))',options['--app-config']],{encoding:'utf8',stdio:['ignore','pipe','pipe']});
    config=JSON.parse(raw);
    if(config.PROJECT_ID!==project||config.BUNDLE_ID!=='com.adnan.augmentmereality'||String(config.GCM_SENDER_ID)!=='895624785272') throw new Error('App configuration mismatch');
  } else if(process.env.FIRESTORE_EMULATOR_HOST!=='127.0.0.1:8191') throw new Error('Expected loopback demo emulator');
  stage='isolated identities';await newAccount('a');await newAccount('b');
  if(ledger.accounts.a.uid===ledger.accounts.b.uid) throw new Error('Identities must differ');
  stage='authorization checks';
  for(const visibility of ['private','link','public']) await createDrop(ids[visibility],'a',visibility);
  await createDrop(ids.viewer,'b','private');
  for(const visibility of ['private','link','public']) {
    const path='drops/'+ids[visibility];
    record('owner reads '+visibility,await doc('GET',path,'a'),200);
    record('owner edits '+visibility,await doc('PATCH',path,'a',{fields:{drop:{mapValue:{fields:{message:s('AMR verified owner edit')}}}}},'?updateMask.fieldPaths=drop.message&currentDocument.exists=true'),200);
    record('viewer reads '+visibility,await doc('GET',path,'b'),visibility==='private'?403:200);
  }
  record('owner scoped refresh',await query('a',eq('ownerUid',ledger.accounts.a.uid),10),200,rows=>rows.filter(r=>r.document).length===3);
  record('viewer own scoped refresh',await query('b',eq('ownerUid',ledger.accounts.b.uid),10),200,rows=>rows.filter(r=>r.document).length===1);
  record('deny unfiltered enumeration (zero-result cap)',await query('b',undefined,0),403);
  for(const visibility of ['link','public']) record('deny '+visibility+' enumeration (zero-result cap)',await query('b',eq('visibility',visibility),0),403);
  record('deny foreign owner enumeration (zero-result cap)',await query('b',eq('ownerUid',ledger.accounts.a.uid),0),403);
  record('deny unauthenticated missing get',await doc('GET','drops/'+ids.missing,'none'),403);
  record('signed-in missing get',await doc('GET','drops/'+ids.missing,'b'),404);
  record('missing delete',await doc('DELETE','drops/'+ids.missing,'b'),200);
  record('repeated missing delete',await doc('DELETE','drops/'+ids.missing,'b'),200);
  record('deny foreign overwrite owner takeover',await doc('PATCH','drops/'+ids.link,'b',{fields:dropFields(ids.link,'b','link')}),403);
  record('deny foreign merge owner takeover',await doc('PATCH','drops/'+ids.link,'b',{fields:{ownerUid:s(ledger.accounts.b.uid)}},'?updateMask.fieldPaths=ownerUid&currentDocument.exists=true'),403);
  record('deny owner transfers ownership',await doc('PATCH','drops/'+ids.link,'a',{fields:{ownerUid:s(ledger.accounts.b.uid)}},'?updateMask.fieldPaths=ownerUid&currentDocument.exists=true'),403);
  record('owner and content unchanged after denied mutations',await doc('GET','drops/'+ids.link,'a'),200,d=>d.fields.ownerUid.stringValue===ledger.accounts.a.uid&&d.fields.drop.mapValue.fields.message.stringValue==='AMR verified owner edit');
  record('deny viewer deletion of owner drop',await doc('DELETE','drops/'+ids.link,'b'),403);
  for(const emoji of ['❤️','😂','🥹','🤯']) record('allowed reaction '+emoji,(await reaction(ids.link,'b',emoji)).result,200);
  record('allowed reaction before parent',(await reaction(ids.orphan,'b','❤️')).result,200);
  record('deny reaction with wrong author',(await reaction(ids.link,'b','❤️',{uid:s(ledger.accounts.a.uid)})).result,403);
  record('deny reaction extra key',(await reaction(ids.link,'b','❤️',{unexpected:s('no')})).result,403);
  record('deny unsupported reaction emoji',(await reaction(ids.link,'b','🎉')).result,403);
  const first=ledger.reactions[0].path;
  record('deny reaction update',await doc('PATCH',first,'b',{fields:{emoji:s('😂')}},'?updateMask.fieldPaths=emoji&currentDocument.exists=true'),403);
  record('parent owner removes reaction',await doc('DELETE',first,'a'),200);
  record('author removes reaction',await doc('DELETE',ledger.reactions[1].path,'b'),200);
  record('owner deletes linked drop',await doc('DELETE','drops/'+ids.link,'a'),200);
  record('deleted link is authoritatively missing for viewer',await doc('GET','drops/'+ids.link,'b'),404);
  record('owner repeats acknowledged delete',await doc('DELETE','drops/'+ids.link,'a'),200);
  evidence.status='passed';
} catch {
  evidence.status='failed';evidence.failedStage=stage;process.exitCode=1;
  console.error('Controlled checks failed during '+stage+'; raw responses and credentials suppressed.');
} finally {
  if(!(await cleanup())) {evidence.status='failed';process.exitCode=1;}
  evidence.finishedAt=new Date().toISOString();
  evidence.checkCount=evidence.checks.length;
  evidence.limits=['REST authorization checks do not substitute for iOS offline/session/UI checks.','Zero-result enumeration probes return no user documents.','No production policy or App Check changes are made by this script.'];
  writeFileSync(join(output,'results.json'),JSON.stringify(evidence,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify({output,status:evidence.status,checkCount:evidence.checkCount,cleanupComplete:evidence.cleanupComplete}));
}
