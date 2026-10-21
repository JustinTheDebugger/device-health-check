import http from 'node:http';
import {createHmac, timingSafeEqual} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
const root=dirname(fileURLToPath(import.meta.url));
const port=Number(process.env.PORT||3000);
const json=(res,status,data)=>{res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(data));};
const authorized=req=>Boolean(process.env.DEVICE_HEALTH_API_TOKEN)&&req.headers.authorization===`Bearer ${process.env.DEVICE_HEALTH_API_TOKEN}`;
const connect=async()=>{if(!process.env.DATABASE_URL)throw Error('DATABASE_URL missing');const {neon}=await import('@neondatabase/serverless');return neon(process.env.DATABASE_URL);};
const sessionName='dh_dashboard_session';
const sessionMaxAge=7*24*60*60;
const secret=()=>process.env.DASHBOARD_SESSION_SECRET||'';
const sign=value=>createHmac('sha256',secret()).update(value).digest('hex');
const safeEqual=(a,b)=>{const x=Buffer.from(String(a));const y=Buffer.from(String(b));return x.length===y.length&&timingSafeEqual(x,y);};
const cookieValue=req=>(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith(sessionName+'='))?.slice(sessionName.length+1)||'';
const loggedIn=req=>{if(!secret())return false;const c=cookieValue(req);const i=c.lastIndexOf('.');if(i<1)return false;const stamp=c.slice(0,i),signature=c.slice(i+1);const expiry=Number(stamp);return Number.isSafeInteger(expiry)&&expiry>Date.now()&&safeEqual(sign(stamp),signature);};
const secureCookie=(value,maxAge)=>`${sessionName}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`;
const sameOrigin=req=>{const origin=req.headers.origin;if(!origin)return false;try{const u=new URL(origin);return u.host===req.headers.host&&u.protocol==='https:';}catch{return false;}};
export async function handler(req,res){
 const path=new URL(req.url,'http://localhost').pathname;
 if(req.method==='GET'&&path==='/api/health')return json(res,200,{ok:true,databaseConfigured:Boolean(process.env.DATABASE_URL),ingestionConfigured:Boolean(process.env.DEVICE_HEALTH_API_TOKEN)});
 if(req.method==='GET'&&(path==='/'||path==='/index.html')){try{const page=await readFile(join(root,'dist/index.html'));res.writeHead(200,{'content-type':'text/html; charset=utf-8'});return res.end(page);}catch{return json(res,503,{error:'Run npm run build first'});}}
 if(path==='/api/dashboard/session'&&req.method==='GET')return json(res,200,{authenticated:loggedIn(req),configured:Boolean(process.env.DASHBOARD_PASSWORD&&secret())});
 if(path==='/api/dashboard/login'&&req.method==='POST'){
  if(!process.env.DASHBOARD_PASSWORD||!secret())return json(res,503,{error:'Dashboard login not configured'});
  if(!sameOrigin(req))return json(res,403,{error:'Invalid request origin'});
  let raw='';for await(const part of req){raw+=part;if(raw.length>4096)return json(res,413,{error:'Request too large'});}
  let password;try{password=JSON.parse(raw).password;}catch{return json(res,400,{error:'Invalid JSON'});}
  if(typeof password!=='string'||!safeEqual(password,process.env.DASHBOARD_PASSWORD))return json(res,401,{error:'Invalid password'});
  const expiry=Date.now()+sessionMaxAge*1000;const stamp=String(expiry);
  res.setHeader('set-cookie',secureCookie(`${stamp}.${sign(stamp)}`,sessionMaxAge));return json(res,200,{ok:true});
 }
 if(path==='/api/dashboard/logout'&&req.method==='POST'){
  if(!sameOrigin(req))return json(res,403,{error:'Invalid request origin'});
  res.setHeader('set-cookie',secureCookie('',0));return json(res,200,{ok:true});
 }
 if(path==='/api/dashboard/reports'&&req.method==='GET'){
  if(!loggedIn(req))return json(res,401,{error:'Dashboard login required'});
  try{const sql=await connect();const rows=await sql`SELECT h.raw_report, d.id AS device_id, d.assigned_user, d.purchase_date::text AS purchase_date FROM device_health_checks h JOIN devices d ON d.id=h.device_id ORDER BY h.collected_at_utc DESC LIMIT 500`;return json(res,200,{reports:rows.map(x=>({...x.raw_report,device_id:x.device_id,assigned_user:x.assigned_user,purchase_date:x.purchase_date}))});}catch(e){console.error('Dashboard query error',e.message);return json(res,503,{error:'Database unavailable'});}
 }
  if(path==='/api/dashboard/device-user'&&req.method==='PUT'){
   if(!loggedIn(req))return json(res,401,{error:'Dashboard login required'});
   if(!sameOrigin(req))return json(res,403,{error:'Invalid request origin'});
   let raw='';for await(const part of req){raw+=part;if(raw.length>2048)return json(res,413,{error:'Request too large'});}
   let payload;try{payload=JSON.parse(raw);}catch{return json(res,400,{error:'Invalid JSON'});}
   const deviceId=Number(payload?.deviceId),assignedUser=payload?.assignedUser,purchaseDate=payload?.purchaseDate;
   if(!Number.isSafeInteger(deviceId)||deviceId<1||typeof assignedUser!=='string'||assignedUser.length>120||typeof purchaseDate!=='string'||(purchaseDate!==''&&!/^\d{4}-\d{2}-\d{2}$/.test(purchaseDate))|| (purchaseDate!=='' && (!Number.isFinite(Date.parse(purchaseDate+'T00:00:00Z')) || new Date(purchaseDate+'T00:00:00Z').toISOString().slice(0,10)!==purchaseDate || purchaseDate>new Date().toISOString().slice(0,10))))return json(res,400,{error:'Invalid device, username or purchase date'});
   try{
    const sql=await connect();
    const rows=await sql`UPDATE devices SET assigned_user=${assignedUser.trim()},purchase_date=${purchaseDate||null},updated_at=now() WHERE id=${deviceId} RETURNING id,assigned_user,purchase_date::text AS purchase_date`;
    if(!rows.length)return json(res,404,{error:'Device not found'});
    return json(res,200,{ok:true,deviceId:rows[0].id,assignedUser:rows[0].assigned_user,purchaseDate:rows[0].purchase_date});
   }catch(e){console.error('Assigned user update error',e.message);return json(res,503,{error:'Database unavailable. Apply the schema migration first.'});}
  }
 if(path==='/api/reports'&&req.method==='GET'){
  if(!authorized(req))return json(res,401,{error:'Unauthorized'});
  try{const sql=await connect();const rows=await sql`SELECT raw_report FROM device_health_checks ORDER BY collected_at_utc DESC LIMIT 500`;return json(res,200,{reports:rows.map(x=>x.raw_report)});}catch(e){console.error('Query error',e.message);return json(res,503,{error:'Database unavailable'});}
 }
 if(path==='/api/ingest'&&req.method==='POST'){
  if(!authorized(req))return json(res,401,{error:'Unauthorized'});
  let raw='';try{for await(const part of req){raw+=part;if(raw.length>200000) return json(res,413,{error:'Payload too large'});}
   const r=JSON.parse(raw);if(!['windows','macos'].includes(r.platform)||typeof r.hostname!=='string'||!r.hostname.trim()||!r.device||!r.metrics||!r.collected_at_utc||!Number.isFinite(Date.parse(r.collected_at_utc)))return json(res,400,{error:'Invalid collector report'});
   const sql=await connect();const device=await sql`INSERT INTO devices(platform,serial_number,hostname,manufacturer,model) VALUES (${r.platform},${r.device.serial_number||null},${r.hostname},${r.device.manufacturer||null},${r.device.model||null}) ON CONFLICT(platform,serial_number) DO UPDATE SET hostname=EXCLUDED.hostname,manufacturer=EXCLUDED.manufacturer,model=EXCLUDED.model,updated_at=now() RETURNING id`;
   const id=device[0].id;await sql`INSERT INTO device_health_checks(device_id,collected_at_utc,schema_version,overall_status,ratings,metrics,processes,raw_report) VALUES (${id},${r.collected_at_utc},${r.schema_version||'1.0'},${r.overall_status||'unknown'},${JSON.stringify(r.ratings||{})}::jsonb,${JSON.stringify(r.metrics)}::jsonb,${JSON.stringify(r.processes||{})}::jsonb,${JSON.stringify(r)}::jsonb) ON CONFLICT(device_id,collected_at_utc) DO NOTHING`;
   return json(res,201,{ok:true,deviceId:id});
  }catch(e){console.error('Ingestion error',e.message);return json(res,503,{error:'Ingestion failed'});}
 }
 return json(res,404,{error:'Not found'});
}
if(process.env.NODE_ENV!=='test')http.createServer((req,res)=>{handler(req,res).catch(e=>{console.error(e);json(res,500,{error:'Server error'});});}).listen(port,()=>console.log(`Device Health app listening on http://localhost:${port}`));
