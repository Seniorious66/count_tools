const $=id=>document.getElementById(id);
const groups=[{id:'morning',name:'晨星'},{id:'night',name:'夜航'}];
const members=[{id:'a',group:'morning',name:'A',color:'#496FA3'},{id:'b',group:'morning',name:'B',color:'#A45D7B'},{id:'c',group:'night',name:'C',color:'#3F826D'},{id:'d',group:'night',name:'D',color:'#966F2E'}];
// 合成演示；发生、录入、实际领取分别记录，刷新恢复。
const seeds=[
 ['r1','2026-10-11T16:00',['a','b'],2,'三寸',[]],
 ['r2','2026-10-11T15:00',['a'],3,'三寸',[[3,'2026-10-11T17:00']]],
 ['r3','2026-10-11T18:00',['b'],2,'五寸',[[1,'2026-10-11T19:00']]],
 ['r4','2026-10-10T15:00',['a'],2,'三寸',[[2,'2026-10-10T16:00']]],
 ['r5','2026-10-10T15:30',['b'],1,'五寸',[[1,'2026-10-10T16:00']]],
 ['r6','2026-10-10T16:00',['a','b'],1,'三寸',[[1,'2026-10-10T17:00']]],
 ['r7','2026-10-10T16:30',['d'],1,'三寸',[[1,'2026-10-10T17:00']]],
 ['r8','2026-10-09T16:00',['c'],2,'五寸',[[2,'2026-10-09T17:00']]],
 ['r9','2026-09-30T23:50',['a'],4,'三寸',[[4,'2026-10-10T17:00']]],
 ['r10','2026-01-01T00:00',['b'],2,'五寸',[]],
 ['r11','2025-12-31T23:59',['c'],3,'三寸',[[3,'2026-01-02T17:00']]],
 ['r12','2026-10-12T00:00',['d'],1,'三寸',[]]
];
const ts=s=>s+':00+08:00';
const records=seeds.map(([id,time,ids,qty,size,received])=>({id,occurredOn:time.slice(0,10),originalOccurredAt:ts(time),members:ids,qty,size,receipts:received.map(([qty,time])=>({qty,at:ts(time),origin:'actual'})),sign:true,back:false,homework:false,createdAt:'2026-10-11T12:00:00+08:00',revision:0,ticketPlan:null}));
const member=id=>members.find(m=>m.id===id),group=id=>groups.find(g=>g.id===id);
const esc=x=>String(x).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sum=rs=>rs.reduce((n,r)=>n+r.qty,0),participation=rs=>rs.reduce((n,r)=>n+r.qty*r.members.length,0);
const received=r=>r.receipts.reduce((n,b)=>n+b.qty,0),pending=r=>r.qty-received(r);
const dateOf=r=>r.occurredOn;
const dateParts=t=>Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(new Date(t)).map(p=>[p.type,p.value]));
const stamp=t=>{if(!t)return'';let p=dateParts(t);return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`};
const localInput=t=>t?stamp(t).slice(0,16).replace(' ','T'):'';
const today=()=>stamp(new Date().toISOString()).slice(0,10);
const receiptLabel=b=>b.origin==='initial'?'初始已领取':stamp(b.at);
const dayDate=s=>new Date(s+'T00:00:00Z'),isoDay=d=>d.toISOString().slice(0,10),pad=n=>String(n).padStart(2,'0');
const addDays=(s,n)=>{let d=dayDate(s);d.setUTCDate(d.getUTCDate()+n);return isoDay(d)};
let recordFilter='all',stats={period:'month',anchor:'2026-10-11',member:null,date:null};
let editingId=null,step=0,draft=null,receiptDraft=[],editBefore=null,demoSequence=0;const history=[];
function bounds(){let a=stats.anchor,d=dayDate(a),start,end,label;if(stats.period==='all')return{start:null,end:null,label:'所有时间'};
 if(stats.period==='day'){start=a;end=addDays(a,1);label=a}
 if(stats.period==='week'){start=addDays(a,-((d.getUTCDay()+6)%7));end=addDays(start,7);label=start+' — '+addDays(end,-1)}
 if(stats.period==='month'){start=a.slice(0,7)+'-01';end=isoDay(new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,1)));label=a.slice(0,7)}
 if(stats.period==='year'){start=a.slice(0,4)+'-01-01';end=(d.getUTCFullYear()+1)+'-01-01';label=a.slice(0,4)+' 年'}return{start,end,label};}
const inRange=(r,b)=>!b.start||(dateOf(r)>=b.start&&dateOf(r)<b.end),statsRows=()=>records.filter(r=>inRange(r,bounds())),memberRows=id=>statsRows().filter(r=>r.members.includes(id));
function stateText(r){return pending(r)===0?'已领取':received(r)===0?'未领取':`部分领取 · 已领 ${received(r)} / ${r.qty}`}
function row(r,opt={}){let color=member(r.members[0]).color,qty=opt.pending?pending(r):r.qty,who=r.members.map(id=>member(id).name).join(' + '),ids=r.members.map(id=>group(member(id).group).name+' · '+member(id).name).join(' / '),attributes=attrs(r);return `<button class="record" data-record="${r.id}"><span class="avatar" style="background:${color}18;border-left:3px solid ${color}">${r.members.map(id=>member(id).name).join('')}</span><span class="record-main"><b>${esc(who)}</b><small>${esc(ids)}</small><small>${r.size} · ${attributes}</small><span class="tag ${pending(r)?'warning-tag':''}">${stateText(r)}</span></span><span class="record-qty"><strong>${qty} 张</strong>${opt.pending?'<small>未领取</small>':''}</span></button>`}
const newest=(a,b)=>dateOf(b).localeCompare(dateOf(a))||b.createdAt.localeCompare(a.createdAt);
function datedList(rs,opt={}){return [...new Set(rs.map(dateOf))].sort().reverse().map(date=>`<div class="section"><h2>${date}</h2><small>${rs.filter(r=>dateOf(r)===date).length} 笔</small></div>`+rs.filter(r=>dateOf(r)===date).sort(newest).map(r=>row(r,opt)).join('')).join('')||'<div class="card empty-day">没有匹配记录。</div>'}
function renderRecords(){let rs=records.filter(r=>dateOf(r).startsWith('2026-10'));$('home-physical').textContent=sum(rs);$('home-participation').textContent='成员累计 '+participation(rs)+' 张';$('pending-total').textContent=records.reduce((n,r)=>n+pending(r),0);$('recent-list').innerHTML=[...records].sort(newest).slice(0,2).map(r=>row(r)).join('');filter(recordFilter)}
function filter(value){recordFilter=value;let rs=records.filter(r=>value==='all'||pending(r)>0);$('record-list').innerHTML=datedList(rs,{pending:value==='pending'});$('record-count').textContent=rs.length+' 笔记录';$('record-physical').textContent=value==='pending'?rs.reduce((n,r)=>n+pending(r),0):sum(rs);$('record-participation').textContent='成员累计 '+rs.reduce((n,r)=>n+(value==='pending'?pending(r):r.qty)*r.members.length,0)+' 张';document.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.filter===value)))}
function navigate(name){document.querySelectorAll('.page').forEach(p=>p.hidden=p.id!==name+'-page');document.querySelectorAll('[data-page]').forEach(b=>b.dataset.page===name?b.setAttribute('aria-current','page'):b.removeAttribute('aria-current'));if(name==='stats')renderStats();$('scroller').scrollTop=0}
function open(title,html){$('dialog-title').textContent=title;$('dialog-body').innerHTML=html;$('dialog-footer').innerHTML='';const footer=$('dialog-body').querySelector('.footer-actions');if(footer)$('dialog-footer').appendChild(footer);$('dialog-footer').hidden=!footer;if(!$('dialog').open)$('dialog').showModal();$('dialog-body').scrollTop=0}
let toastTimer;function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,3500)}
function renderMembers(){let visible=members.filter(m=>$('stats-group').value==='all'||m.group===$('stats-group').value),rs=statsRows().filter(r=>r.members.some(id=>visible.some(m=>m.id===id))),total=visible.reduce((n,m)=>n+sum(memberRows(m.id)),0);$('stats-physical').textContent=sum(rs)+' 张';$('stats-range-label').textContent=bounds().label;$('stats-date').disabled=stats.period==='all';$('stats-date').value=stats.anchor;document.querySelectorAll('[data-period]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.period===stats.period)));document.querySelectorAll('[data-shift]').forEach(b=>b.disabled=stats.period==='all');$('stats-members').innerHTML='<div class="card member-list">'+visible.map(m=>{let q=sum(memberRows(m.id)),p=total?q/total*100:0;return `<button class="member-row" data-member="${m.id}" aria-label="查看${group(m.group).name}成员${m.name}每日张数"><div class="member-heading"><span><i style="background:${m.color}"></i><span class="member-name">${group(m.group).name} · ${m.name}</span></span><b>${q} 张 <small>${total?p.toFixed(1)+'%':'—'}</small> ›</b></div><div class="track"><div class="fill member-fill" style="background:${m.color};width:${p}%"></div></div></button>`}).join('')+'</div>'}
function renderStats(){renderMembers();let detail=stats.member!==null;$('stats-overview').hidden=detail;$('stats-detail').hidden=!detail;if(!detail)return;let m=member(stats.member),rs=memberRows(m.id);if(stats.date){renderDay(m,rs.filter(r=>dateOf(r)===stats.date));return}
 let dates=[...new Set(rs.map(dateOf))].sort().reverse(),days=dates.map(date=>({date,qty:sum(rs.filter(r=>dateOf(r)===date))})),max=Math.max(1,...days.map(d=>d.qty)),calendar='';
 if(stats.period==='month'){let y=Number(stats.anchor.slice(0,4)),mo=Number(stats.anchor.slice(5,7)),count=new Date(Date.UTC(y,mo,0)).getUTCDate(),offset=(new Date(Date.UTC(y,mo-1,1)).getUTCDay()+6)%7;calendar='<span aria-hidden="true"></span>'.repeat(offset);for(let day=1;day<=count;day++){let date=stats.anchor.slice(0,7)+'-'+pad(day),q=sum(rs.filter(r=>dateOf(r)===date));calendar+=`<button class="calendar-day ${q?'has-record':''}" data-date="${date}" aria-label="${date}，${q}张" style="--member-color:${m.color}"><span>${day}</span><b>${q?q+'张':'·'}</b></button>`}}
 let b=bounds();$('stats-detail').innerHTML=`<header class="header detail-header"><button class="icon" data-stats-back="list" aria-label="返回成员列表">‹</button><div><h1>${m.name} 的统计</h1><small>${group(m.group).name} · ${m.name}</small></div><button class="icon" data-action="member-settings" aria-label="成员颜色设置"><svg><use href="#settings"/></svg></button></header><div class="card member-total" style="border-left:4px solid ${m.color}"><small>${b.label}</small><strong class="number">${sum(rs)} 张</strong><small>单人 ${sum(rs.filter(r=>r.members.length===1))} · 多人 ${sum(rs.filter(r=>r.members.length>1))}</small></div><div class="section"><h2>每日张数</h2><small>点击日期看记录</small></div><label class="field ${calendar?'narrow-date-picker':''}"><span>查看日期（所选范围内）</span><input id="member-date-input" type="date" ${b.start?`min="${b.start}" max="${addDays(b.end,-1)}"`:''} value="${stats.anchor}"></label>${calendar?`<div class="card calendar-card"><div class="calendar weekdays">${['一','二','三','四','五','六','日'].map(x=>'<span>'+x+'</span>').join('')}</div><div class="calendar">${calendar}</div></div>`:''}<div class="section"><h2>有记录的日期</h2><small>${dates.length} 天</small></div><div class="card day-list">${days.map(d=>`<button class="daily-row" data-date="${d.date}"><div class="member-heading"><span>${d.date}</span><b>${d.qty} 张 ›</b></div><div class="track"><div class="fill daily-fill" style="background:${m.color};width:${d.qty/max*100}%"></div></div></button>`).join('')||'<p class="info">所选范围暂无记录。</p>'}</div>`;}
function renderDay(m,rs){$('stats-detail').innerHTML=`<header class="header detail-header"><button class="icon" data-stats-back="member" aria-label="返回成员统计">‹</button><div><h1>${stats.date}</h1><small>${group(m.group).name} · ${m.name}</small></div></header><div class="card member-total" style="border-left:4px solid ${m.color}"><small>${m.name} 当天的 Cheki</small><strong class="number" id="day-total">${sum(rs)} 张</strong><small>三寸 ${sum(rs.filter(r=>r.size==='三寸'))} · 五寸 ${sum(rs.filter(r=>r.size==='五寸'))}</small></div><div class="section"><h2>当天记录</h2><small>${rs.length} 笔</small></div><div id="member-day-records">${rs.map(r=>row(r)).join('')||'<div class="card empty-day">当天没有记录，统计为 0 张。</div>'}</div>`}
function openMemberSettings(){open('成员颜色设置','<p class="info">合成设置，刷新重置。成员与每日条形、月历标记使用同一设置色。</p>'+members.map(m=>`<label class="color-setting"><span>${group(m.group).name} · ${m.name}</span><input type="color" data-color-member="${m.id}" value="${m.color}" aria-label="${group(m.group).name}成员${m.name}颜色"></label>`).join(''))}
function showRecord(id){
 const r=records.find(r=>r.id===id);
 open('记录详情',`<div class="review-row"><span>发生日期</span><span>${r.occurredOn}</span></div><div class="review-row"><span>录入时间</span><span>${stamp(r.createdAt)}</span></div>${r.updatedAt?`<div class="review-row"><span>修改时间</span><span>${stamp(r.updatedAt)}</span></div>`:''}<div class="review-row"><span>成员</span><span>${r.members.map(id=>group(member(id).group).name+' · '+member(id).name).join('<br>')}</span></div><div class="review-row"><span>张数</span><span>${r.qty} 张</span></div><div class="review-row"><span>属性</span><span>${r.size} · ${attrs(r)}</span></div><div class="review-row"><span>领取</span><span>${stateText(r)}</span></div>${receiptRows(r)}<button class="primary" data-edit="${id}" style="width:100%;margin-top:20px">修改记录</button>`);
}
const attrs=r=>[r.homework?'宿题':r.sign?'有签':'无签',r.back?'背签':''].filter(Boolean).join(' · ');
function attributesHtml(){
 return `<fieldset class="attribute-field"><legend>属性</legend><div class="checks attribute-options">${[['unsigned','无签',!draft.sign&&!draft.homework],['sign','有签',draft.sign],['homework','宿题',draft.homework]].map(([k,n,checked])=>`<label><input id="${k}-input" data-sign-choice="${k}" type="checkbox" ${checked?'checked':''}>${n}</label>`).join('')}<label><input id="back-input" type="checkbox" ${draft.back?'checked':''} ${draft.sign&&!draft.homework?'':'disabled'}>背签</label></div></fieldset>`;
}
function syncAttributes(){
 $('unsigned-input').checked=!draft.sign&&!draft.homework;$('sign-input').checked=draft.sign;$('homework-input').checked=draft.homework;
 $('back-input').disabled=!draft.sign||draft.homework;$('back-input').checked=draft.back;
}
const receiptRows=r=>r.receipts.filter(b=>b.origin!=='initial').map(b=>`<div class="review-row"><span>领取 ${b.qty} 张</span><span>${stamp(b.at)}</span></div>`).join('');
const receiptMode=r=>received(r)===0?'none':pending(r)===0?'all':'partial';
const couponTypes=[{id:'a-base',name:'晨星 · A 基础券',group:'morning',member:'a',limited:4,long:8},{id:'morning-common',name:'晨星 · 通用券',group:'morning',member:null,limited:0,long:2}];
const availableCoupons=id=>couponTypes.filter(t=>t.group===member(id).group&&(!t.member||t.member===id));
function resetAllocation(){
 const choices=draft.couponChoices;
 for(const id of draft.members)if(!availableCoupons(id).some(t=>t.id===choices[id]))choices[id]=availableCoupons(id)[0]?.id||'';
 draft.allocations=couponTypes.flatMap(t=>{
  const needed=draft.members.filter(id=>choices[id]===t.id).length*draft.qty;
  if(!needed)return[];
  const limited=Math.min(t.limited,needed),long=Math.min(t.long,Math.max(0,needed-limited));
  return[{id:t.id,needed,limited,long}];
 });
}
function beginRecord(id=null){
 editingId=id;step=0;editBefore=id?structuredClone(records.find(r=>r.id===id)):null;
 draft=editBefore?structuredClone(editBefore):{occurredOn:today(),members:['a'],qty:1,size:'三寸',sign:true,back:false,homework:false,receipts:[{qty:1,at:null,origin:'initial'}],ticketPlan:null};
 receiptDraft=structuredClone(draft.receipts);draft.receiptMode=receiptMode(draft);draft.use='deduct';draft.couponChoices={};resetAllocation();wizard();
}
function membersHtml(){
 const available=members.filter(m=>!draft.members.includes(m.id));
 return `<label class="field"><span>参与成员</span><select id="member-picker" ${available.length?'':'disabled'}><option value="">选择成员…</option>${groups.map(g=>`<optgroup label="${g.name}">${available.filter(m=>m.group===g.id).map(m=>`<option value="${m.id}">${g.name} · ${m.name}</option>`).join('')}</optgroup>`).join('')}</select></label><div class="selected-members">${draft.members.map(id=>`<button class="member-chip" data-remove-member="${id}" aria-label="移除${group(member(id).group).name}成员${member(id).name}">${group(member(id).group).name} · ${member(id).name}<span aria-hidden="true">×</span></button>`).join('')}</div>`;
}
function receiptsHtml(){
 const batches=receiptDraft.map((b,i)=>b.origin==='initial'?`<div class="receipt-batch"><span>初始已领取 ${b.qty} 张</span></div>`:`<div class="receipt-batch"><div class="form-row"><label class="field"><span>已领取张数</span><input data-receipt-qty="${i}" type="number" min="1" max="${draft.qty}" value="${b.qty}"></label><label class="field"><span>领取时间</span><input data-receipt-time="${i}" type="datetime-local" value="${localInput(b.at)}"></label></div><button class="text-link" data-remove-receipt="${i}">移除此领取批次</button></div>`).join('');
 const show=draft.receiptMode==='partial'||receiptDraft.some(b=>b.origin!=='initial');
 return `<label class="field"><span>领取状态</span><select id="receipt-status">${[['all','已领取'],['partial','部分领取'],['none','未领取']].map(([value,name])=>`<option value="${value}" ${draft.receiptMode===value?'selected':''}>${name}</option>`).join('')}</select></label>${show?`<div id="receipt-batches">${batches}<button class="text-link" id="add-receipt">＋ 添加领取批次</button></div>`:''}`;
}
function allocationHtml(){
 return `<label class="field"><span>用券方式</span><select id="use-input"><option value="deduct" ${draft.use==='deduct'?'selected':''}>记录并扣券</option><option value="none" ${draft.use==='none'?'selected':''}>仅记录，不扣券</option></select></label><div id="allocation-summary" aria-live="polite"></div><section class="allocation-details" ${draft.use==='none'?'hidden':''}><h3>扣券明细</h3>${draft.members.map(id=>`<label class="field"><span>${group(member(id).group).name} · ${member(id).name}</span><select data-coupon-member="${id}"><option value="">选择券种…</option>${availableCoupons(id).map(t=>`<option value="${t.id}" ${draft.couponChoices[id]===t.id?'selected':''}>${t.name}</option>`).join('')}</select></label>`).join('')}${draft.allocations.map(a=>{let t=couponTypes.find(t=>t.id===a.id);return `<div class="section"><h3>${t.name}</h3><small data-needed="${t.id}">所需 ${a.needed} 张</small></div><div class="form-row"><label class="field"><span>限时（可用 ${t.limited}）</span><input data-pool="limited" data-coupon="${t.id}" type="number" min="0" max="${t.limited}" value="${a.limited}"></label><label class="field"><span>长期（可用 ${t.long}）</span><input data-pool="long" data-coupon="${t.id}" type="number" min="0" max="${t.long}" value="${a.long}"></label></div>`}).join('')}<button id="reset-allocation" class="text-link">恢复自动</button></section>`;
}
function couponSummary(){return draft.use==='none'?'不扣券':draft.allocations.map(a=>`${couponTypes.find(t=>t.id===a.id).name} ${a.limited+a.long} 张（限时 ${a.limited} · 长期 ${a.long}）`).join('<br>')}
function wizard(){
 let body='<div class="steps two-steps">'+['记录','核对'].map((n,i)=>`<span class="step ${i===step?'active':''}">${i+1} ${n}</span>`).join('')+'</div><p class="info">合成演示，刷新重置，不写入 App 或券库存。</p>';
 if(!step){
  body+=`<label class="field"><span>发生日期</span><input id="event-input" type="date" value="${draft.occurredOn}"></label>${membersHtml()}<div class="form-row"><label class="field"><span>尺寸</span><select id="size-input"><option ${draft.size==='三寸'?'selected':''}>三寸</option><option ${draft.size==='五寸'?'selected':''}>五寸</option></select></label><label class="field"><span>张数</span><input id="qty-input" type="number" min="1" step="1" value="${draft.qty}"></label></div>${attributesHtml()}${receiptsHtml()}`;
  body+=editingId?'<p class="info">保留原用券关联；正式版本须先核对券与成本影响。</p>':allocationHtml();
 }else{
  body+=`<div class="review-row"><span>发生日期</span><span>${draft.occurredOn}</span></div><div class="review-row"><span>成员</span><span>${draft.members.map(id=>group(member(id).group).name+' · '+member(id).name).join('<br>')}</span></div><div class="review-row"><span>张数</span><span>${draft.qty} 张</span></div><div class="review-row"><span>属性</span><span>${draft.size} · ${attrs(draft)}</span></div><div class="review-row"><span>领取</span><span>${stateText(draft)}</span></div>${receiptRows(draft)}<div class="review-row"><span>用券</span><span>${editingId?'保留原关联':couponSummary()}</span></div>`;
  if(editBefore)body+=`<div class="card change-preview"><h3>修改预览</h3><p>发生日期：${editBefore.occurredOn} → ${draft.occurredOn}</p><p>张数：${editBefore.qty} → ${draft.qty}</p><p>成员：${editBefore.members.map(id=>group(member(id).group).name+' · '+member(id).name).join(' / ')} → ${draft.members.map(id=>group(member(id).group).name+' · '+member(id).name).join(' / ')}</p><p>属性：${editBefore.size} · ${attrs(editBefore)} → ${draft.size} · ${attrs(draft)}</p><p>领取：${stateText(editBefore)} → ${stateText(draft)}</p><p>领取批次：${editBefore.receipts.map(b=>b.qty+' 张 '+receiptLabel(b)).join('；')||'—'} → ${draft.receipts.map(b=>b.qty+' 张 '+receiptLabel(b)).join('；')||'—'}</p></div>`;
 }
 body+='<div id="wizard-error" role="alert"></div><div class="footer-actions">'+(step?'<button id="previous-step">返回记录</button>':'')+`<button class="primary" id="next-step">${step?'确认演示':'下一步：核对'}</button></div>`;
 open(editingId?'修改记录':'记一笔',body);$('next-step').onclick=next;
 if(step){$('previous-step').onclick=()=>{step=0;wizard()};return}
 document.querySelectorAll('[data-sign-choice]').forEach(el=>el.onchange=()=>{
  const previous={sign:draft.sign,homework:draft.homework},selected=el.checked;
  saveFields();
  if(selected){draft.sign=el.dataset.signChoice==='sign';draft.homework=el.dataset.signChoice==='homework'}
  else Object.assign(draft,previous);
  if(!draft.sign||draft.homework)draft.back=false;
  syncAttributes();
 });
 $('member-picker').onchange=()=>{let id=$('member-picker').value;if(!id)return;saveFields();draft.members.push(id);resetAllocation();wizard()};
 $('qty-input').onchange=()=>{saveFields();if(receiptDraft.length===1&&receiptDraft[0].origin==='initial'&&draft.receiptMode==='all')receiptDraft[0].qty=draft.qty;else if(received(draft)>0&&received(draft)<draft.qty)draft.receiptMode='partial';draft.receipts=structuredClone(receiptDraft);resetAllocation();wizard()};
 $('qty-input').oninput=()=>{
  saveFields();
  if(!editingId){
   document.querySelectorAll('[data-pool]').forEach(el=>{const a=draft.allocations.find(a=>a.id===el.dataset.coupon);if(a)el.value=a[el.dataset.pool]});
   document.querySelectorAll('[data-needed]').forEach(el=>{const a=draft.allocations.find(a=>a.id===el.dataset.needed);if(a)el.textContent='所需 '+a.needed+' 张'});
   allocation();
  }
 };
 $('receipt-status').onchange=()=>{
  const mode=$('receipt-status').value;saveFields();draft.receiptMode=mode;
  if(mode==='none')receiptDraft=[];
  if(mode==='all'){
   if(!editingId)receiptDraft=[{qty:draft.qty,at:null,origin:'initial'}];
   else if(received(draft)<draft.qty)receiptDraft.push({qty:draft.qty-received(draft),at:null,origin:'actual'});
  }
  if(mode==='partial'&&!editingId&&receiptDraft.some(b=>b.origin==='initial'))receiptDraft=[];
  if(mode==='partial'&&!receiptDraft.length)receiptDraft=[{qty:1,at:null,origin:'actual'}];
  draft.receipts=structuredClone(receiptDraft);wizard();
 };
 if($('add-receipt'))$('add-receipt').onclick=()=>{saveFields();receiptDraft.push({qty:1,at:null,origin:'actual'});draft.receipts=structuredClone(receiptDraft);wizard()};
 if(!editingId){
  $('use-input').onchange=()=>{saveFields();wizard()};
  document.querySelectorAll('[data-coupon-member]').forEach(el=>el.onchange=()=>{saveFields();draft.couponChoices[el.dataset.couponMember]=el.value;resetAllocation();wizard()});
  document.querySelectorAll('[data-pool]').forEach(el=>el.oninput=()=>{saveFields();allocation()});
  $('reset-allocation').onclick=()=>{saveFields();resetAllocation();wizard()};allocation();
 }
}
function saveFields(){
 if(step)return;
 const previousQty=draft.qty;
 draft.occurredOn=$('event-input').value;draft.qty=Number($('qty-input').value);draft.size=$('size-input').value;draft.sign=$('sign-input').checked;
 for(const k of ['back','homework'])draft[k]=$(k+'-input').checked;
 receiptDraft=receiptDraft.map((b,i)=>{const q=document.querySelector(`[data-receipt-qty="${i}"]`),t=document.querySelector(`[data-receipt-time="${i}"]`);return q?{qty:Number(q.value),at:t.value?(t.value===localInput(b.at)?b.at:ts(t.value)):null,origin:'actual'}:b});
 if(receiptDraft.length===1&&receiptDraft[0].origin==='initial'&&draft.receiptMode==='all')receiptDraft[0].qty=draft.qty;
 draft.receipts=structuredClone(receiptDraft);
 if($('use-input')){draft.use=$('use-input').value;draft.allocations=draft.allocations.map(a=>({...a,...Object.fromEntries(['limited','long'].map(pool=>[pool,Number(document.querySelector(`[data-coupon="${a.id}"][data-pool="${pool}"]`).value)]))}));}
 if(draft.qty!==previousQty)resetAllocation();
}
function allocationError(){
 if(draft.use==='none')return'';
 if(draft.members.some(id=>!draft.couponChoices[id]))return'部分成员没有可用券种，请选券或改为仅记录。';
 for(const a of draft.allocations){const t=couponTypes.find(t=>t.id===a.id),total=a.limited+a.long;
  if(!Number.isInteger(a.limited)||!Number.isInteger(a.long)||a.limited<0||a.long<0||a.limited>t.limited||a.long>t.long)return t.name+' 的分配超出库存或不是有效整数。';
  if(total!==a.needed)return t.name+`：已分配 ${total}，${total<a.needed?'尚差 '+(a.needed-total):'超出 '+(total-a.needed)} 张。`;
 }
 return'';
}
function allocation(){const error=allocationError(),el=$('allocation-summary');el.className=error?'error':'success-note';el.textContent=error|| (draft.use==='none'?'不扣券':`将扣 ${draft.allocations.reduce((n,a)=>n+a.limited+a.long,0)} 张券`);$('next-step').disabled=Boolean(error);return !error}
function validate(){
 if((draft.sign&&draft.homework)||(draft.back&&(!draft.sign||draft.homework))||document.querySelectorAll('[data-sign-choice]:checked').length!==1)return'无签、有签、宿题须选一项；背签仅有签可用。';
 if(!/^\d{4}-\d{2}-\d{2}$/.test(draft.occurredOn)||!Number.isFinite(Date.parse(draft.occurredOn))||!Number.isInteger(draft.qty)||draft.qty<1||!draft.members.length)return'请选择发生日期、至少一位成员和正整数张数。';
 if(draft.receipts.some(b=>!Number.isInteger(b.qty)||b.qty<1||(b.origin!=='initial'&&(!b.at||!Number.isFinite(Date.parse(b.at))))))return'领取批次需要正整数张数和领取时间。';
 if(received(draft)>draft.qty)return'已领取张数不能超过总张数。';
 if(draft.receiptMode==='partial'&&(received(draft)<=0||received(draft)>=draft.qty))return'部分领取的已领张数须大于 0 且小于总张数。';
 if(draft.receiptMode==='all'&&pending(draft)!==0)return'已领取需要领取全部张数。';
 if(draft.receipts.some(b=>b.at&&stamp(b.at).slice(0,10)<draft.occurredOn))return'领取日期不能早于发生日期，请核对。';
 if(!editingId)return allocationError();return'';
}
function next(){
 if(!step){saveFields();const error=validate();if(error){$('wizard-error').className='error';$('wizard-error').textContent=error;return}step=1;wizard();return}
 const value=structuredClone(draft),now=new Date().toISOString();
 for(const key of ['use','allocations','couponChoices','receiptMode'])delete value[key];
 if(editingId){let i=records.findIndex(r=>r.id===editingId);value.updatedAt=now;value.revision=records[i].revision+1;history.push({id:editingId,before:structuredClone(records[i]),after:structuredClone(value),at:now});records[i]=value}
 else{value.id='demo-'+(++demoSequence);value.createdAt=now;value.revision=0;value.ticketPlan=draft.use==='deduct'?structuredClone(draft.allocations):null;records.unshift(value)}
 $('dialog').close();renderRecords();renderStats();toast('已应用到合成演示；券库存未扣减，刷新重置');
}
function shift(n){if(stats.period==='all')return;let d=dayDate(stats.anchor);if(stats.period==='day')stats.anchor=addDays(stats.anchor,n);if(stats.period==='week')stats.anchor=addDays(stats.anchor,7*n);if(stats.period==='month')stats.anchor=isoDay(new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+n,1)));if(stats.period==='year')stats.anchor=(d.getUTCFullYear()+n)+'-01-01';renderStats()}
function action(name){if(name==='register')beginRecord();if(name==='manage')open('管理','<div class="management">'+['团体与成员','券种与尺寸','备份与恢复','批量导入导出','设置'].map(x=>`<button data-management="${x}">${x}　›</button>`).join('')+'</div>');if(name==='member-settings')openMemberSettings();if(name==='buy')open('购券','<p class="info">购券入口 · 合成演示，不改变库存</p><label class="field"><span>券种与归属</span><select><option>晨星 · A 基础券（个人券）</option><option>晨星 · 通用券（团体券）</option></select></label><div class="form-row"><label class="field"><span>购入数量</span><input type="number" min="1" value="2"></label><label class="field"><span>总金额（元）</span><input type="number" min="0" value="60"></label></div><button class="secondary" data-action="buy-finish" style="width:100%;margin-top:20px">结束购券演示</button>');if(name==='buy-finish'){$('dialog').close();toast('购券演示结束，库存未改变')}if(name==='expiry')open('晨星 · A 基础券','<div class="card ticket-hero"><h3>晨星 · A 基础券</h3><strong class="number">4 张可用</strong><small>10 月 15 日截止 · 临期</small></div><p class="info">过期券保留并单列，只有主动手选才能使用。</p>');if(name==='ticket-detail')open('晨星 · 通用券','<p class="info">晨星 · 团体通用券</p><div class="review-row"><span>长期可用</span><b>2 张</b></div><div class="review-row"><span>过期 · 10/01</span><b>1 张</b></div><div class="management">'+['购入流水','成本来源','交换','赠送','库存调整'].map(x=>`<button data-management="${x}">${x}　›</button>`).join('')+'</div>')}
document.addEventListener('click',ev=>{let b=ev.target.closest('button');if(!b)return;if(b.dataset.page)navigate(b.dataset.page);if(b.dataset.go)navigate(b.dataset.go);if(b.dataset.filterGo){navigate('records');filter(b.dataset.filterGo)}if(b.dataset.filter)filter(b.dataset.filter);if(b.dataset.action)action(b.dataset.action);if(b.dataset.management){if(b.dataset.management==='团体与成员')openMemberSettings();else toast(b.dataset.management+'：设计入口')}if(b.dataset.record)showRecord(b.dataset.record);if(b.dataset.edit)beginRecord(b.dataset.edit);if(b.dataset.member){stats.member=b.dataset.member;stats.date=null;renderStats();$('scroller').scrollTop=0}if(b.dataset.date){stats.date=b.dataset.date;renderStats();$('scroller').scrollTop=0}if(b.dataset.statsBack){if(b.dataset.statsBack==='list')stats.member=null;stats.date=null;renderStats();$('scroller').scrollTop=0}if(b.dataset.period){stats.period=b.dataset.period;renderStats()}if(b.dataset.shift)shift(Number(b.dataset.shift));if(b.dataset.removeMember){saveFields();draft.members=draft.members.filter(id=>id!==b.dataset.removeMember);resetAllocation();wizard()}if(b.dataset.removeReceipt!==undefined){saveFields();receiptDraft.splice(Number(b.dataset.removeReceipt),1);draft.receipts=structuredClone(receiptDraft);wizard()}});
document.addEventListener('input',ev=>{if(ev.target.dataset.colorMember){member(ev.target.dataset.colorMember).color=ev.target.value;renderRecords();renderStats()}});
document.addEventListener('change',ev=>{if(ev.target.id==='stats-date'&&ev.target.value){stats.anchor=ev.target.value;renderStats()}if(ev.target.id==='member-date-input'&&ev.target.value){let b=bounds();if(!b.start||(ev.target.value>=b.start&&ev.target.value<b.end)){stats.date=ev.target.value;renderStats();$('scroller').scrollTop=0}else toast('请选择当前统计范围内的日期')}});
$('stats-group').onchange=renderStats;$('close-dialog').onclick=()=>{$('dialog').close();toast('已退出当前表单，未应用修改')};renderRecords();renderStats();
