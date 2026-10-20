import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
const root=dirname(fileURLToPath(import.meta.url));
const port=Number(process.env.PORT||3000);
const json=(res,status,data)=>{res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(data));};
const authorized=req=>Boolean(process.env.DEVICE_HEALTH_API_TOKEN)&&req.headers.authorization===`Bearer ${process.env.DEVICE_HEALTH_API_TOKEN}`;
const connect=async()=>{if(!process.env.DATABASE_URL)throw Error('DATABASE_URL missing');const {neon}=await import('@neondatabase/serverless');return neon(process.env.DATABASE_URL);};
export async function handler(req,res){
 const path=new URL(req.url,'http://localhost').pathname;
 if(req.method==='GET'&&path==='/api/health')return json(res,200,{ok:true,databaseConfigured:Boolean(process.env.DATABASE_URL),ingestionConfigured:Boolean(process.env.DEVICE_HEALTH_API_TOKEN)});
 if(req.method==='GET'&&(path==='/'||path==='/index.html')){try{const page=await readFile(join(root,'dist/index.html'));res.writeHead(200,{'content-type':'text/html; charset=utf-8'});return res.end(page);}catch{return json(res,503,{error:'Run npm run build first'});}}
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
