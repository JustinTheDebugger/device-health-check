import PDFDocument from 'pdfkit';
const n=v=>v===null||v===undefined||v===''?null:Number(v);
const pct=v=>n(v)===null||!Number.isFinite(n(v))?'N/A':`${n(v).toFixed(1)}%`;
const clean=v=>String(v??'Unknown').replace(/[\u0000-\u001f]/g,' ').slice(0,140);
const latestRows=rows=>[...new Map(rows.map(r=>[r.device_id,r])).values()];
export function createManagementPdf(rows,generatedAt=new Date()){
 const devices=latestRows(rows),total=devices.length;
 const good=devices.filter(r=>r.overall_status==='good').length;
 const warning=devices.filter(r=>r.overall_status==='warning').length;
 const critical=devices.filter(r=>r.overall_status==='critical').length;
 const mac=devices.filter(r=>r.platform==='macos').length;
 const storage=devices.filter(r=>n(r.metrics?.storage_free_percent)!==null&&n(r.metrics.storage_free_percent)<20);
 const ram=devices.filter(r=>n(r.metrics?.ram_used_percent)!==null&&n(r.metrics.ram_used_percent)>=90);
 const battery=devices.filter(r=>n(r.metrics?.battery_health_percent)!==null&&n(r.metrics.battery_health_percent)<80);
 const missing=devices.filter(r=>!r.purchase_date);
 const flagged=devices.filter(r=>r.overall_status==='critical'||r.overall_status==='warning'||storage.includes(r)||ram.includes(r)||battery.includes(r));
 const doc=new PDFDocument({size:'A4',margin:44,bufferPages:true,info:{Title:'Zempire Device Health Management Report (NZ)',Author:'Zempire Device Health Console'}});
 const chunks=[];doc.on('data',b=>chunks.push(b));
 const navy='#18344f'; const grey='#516274';const pageBottom=760;
 function ensure(h=45){if(doc.y+h>pageBottom)doc.addPage();}
 function heading(t){ensure(45);doc.moveDown(.65).font('Helvetica-Bold').fontSize(14).fillColor(navy).text(t);doc.moveDown(.35);}
 function para(t){ensure(48);doc.font('Helvetica').fontSize(9.5).fillColor('#243444').text(t,{lineGap:3});}
 function table(headers,rows,widths){const x=44;const rowHeight=23;ensure(rowHeight*2);let y=doc.y;function row(vals,head=false){ensure(rowHeight);y=doc.y;doc.rect(x,y,507,rowHeight).fill(head?navy:(Math.round(y/rowHeight)%2?'#f0f4f7':'#ffffff'));let offset=x+6;vals.forEach((v,i)=>{doc.fillColor(head?'#ffffff':'#253749').font(head?'Helvetica-Bold':'Helvetica').fontSize(8).text(clean(v),offset,y+7,{width:widths[i]-10,height:13,ellipsis:true});offset+=widths[i]});doc.y=y+rowHeight;};row(headers,true);for(const r of rows)row(r);doc.moveDown(.3);}
 doc.font('Helvetica-Bold').fontSize(20).fillColor(navy).text('Zempire Device Health Management Report (NZ)');
 doc.moveDown(.25).font('Helvetica').fontSize(9).fillColor(grey).text(`Live NeonDB snapshot | Generated ${generatedAt.toLocaleString('en-NZ',{timeZone:'Pacific/Auckland',dateStyle:'long',timeStyle:'short'})} NZ time`);
 heading('Executive summary');
 para(`${total} devices assessed: ${good} healthy, ${warning} warning, ${critical} critical, and ${total-good-warning-critical} other/unknown. This is a latest-check-in snapshot, not evidence of sustained problems. Prioritise targeted investigation before recommending replacement.`);
 heading('Fleet overview');
 table(['Metric','Result'],[['Devices / platforms',`${total} total | ${mac} macOS | ${total-mac} Windows`],['Overall health',`${good} good | ${warning} warning | ${critical} critical`],['Missing purchase dates',`${missing.length} of ${total}`],['Less than 20% free storage',`${storage.length} devices`],['RAM used at least 90%',`${ram.length} devices`],['Battery health below 80%',`${battery.length} devices`]], [254,253]);
 heading('Key risks and management actions');
 if(!flagged.length)para('No warning/critical or threshold-based issues in the current readings. Continue routine checks.');
 else {
  const risks=flagged.map(r=>{const m=r.metrics||{};let issues=[];if(n(m.storage_free_percent)!==null&&n(m.storage_free_percent)<20)issues.push(`Storage ${pct(m.storage_free_percent)} free`);if(n(m.ram_used_percent)!==null&&n(m.ram_used_percent)>=90)issues.push(`RAM ${pct(m.ram_used_percent)}`);if(n(m.battery_health_percent)!==null&&n(m.battery_health_percent)<80)issues.push(`Battery ${pct(m.battery_health_percent)}`);if(!issues.length)issues.push(`Status ${r.overall_status}`);let action=issues.some(x=>x.startsWith('Battery'))?'Assess battery condition and service cost':issues.some(x=>x.startsWith('Storage'))?'Free storage and rerun check':issues.some(x=>x.startsWith('RAM'))?'Review applications and repeat RAM check':'Review detailed health indicators';return [r.assigned_user||r.hostname,issues.join('; '),action]});
  table(['Device / owner','Observed indicators','Recommended action'],risks,[130,177,200]);
 }
 heading('Device-level register');
 const ordered=[...devices].sort((a,b)=>clean(a.assigned_user||a.hostname).localeCompare(clean(b.assigned_user||b.hostname)));
 table(['User / device','Platform','Health','RAM','Free disk','Battery'],ordered.map(r=>[r.assigned_user||r.hostname,r.platform,r.overall_status,pct(r.metrics?.ram_used_percent),pct(r.metrics?.storage_free_percent),pct(r.metrics?.battery_health_percent)]),[146,62,79,67,76,77]);
 heading('Capital expenditure and asset lifecycle');
 para(`Purchase dates are missing for ${missing.length} of ${total} devices. Confirm age, warranty, repair estimates and actual user impact before proposing capital expenditure. A single health snapshot does not establish the need for whole-device replacement.`);
 heading('30-day action plan');
 para('Week 1: address low free storage and assess battery health exceptions. Weeks 2-3: repeat high RAM measurements and confirm user impact. By day 30: complete purchase dates, record completed actions, and rerun collectors to compare readings.');
 heading('Data interpretation and limitations');
 para('This report uses the latest stored check-in per device, fetched from NeonDB when the download was requested. Some values may have been manually edited for testing, including previously adjusted Mac uptime readings; the database does not currently identify which values were edited. Treat such values as unverified until a fresh collector check-in. Missing battery readings do not imply healthy batteries. Metrics are snapshots, not continuous monitoring.');
 const count=doc.bufferedPageRange().count;for(let i=0;i<count;i++){doc.switchToPage(i);doc.fontSize(8).font('Helvetica').fillColor(grey).text(`Zempire | Internal management review                                       Page ${i+1} of ${count}`,44,800,{width:510,align:'center'});}doc.end();return new Promise((resolve,reject)=>{doc.on('end',()=>resolve(Buffer.concat(chunks)));doc.on('error',reject)});
}
