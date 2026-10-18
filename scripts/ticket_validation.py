"""Read-only schema 6 ticket ledger, exact cost, references and audit validation."""
import datetime
import json
import re
from fractions import Fraction
from catalog_validation import action_stamp,decode_json,decode_row,table_rows
OBJECTS='cheki_ticket_objects';OPS='cheki_ticket_operations';HISTORY='cheki_ticket_history'
FIELDS=('seq','id','kind','information_json','posted','allocations_json','revision','created_at','updated_at')
def money(text):
    if not isinstance(text,str) or len(text)>80 or not re.fullmatch(r'\d+(?:\.\d+)?',text):raise ValueError('Ticket amount invalid')
    return Fraction(text)
def info(raw):
    v=decode_json(raw)
    if v.get('recorded_at') is not None and not action_stamp(v['recorded_at']):raise ValueError('Ticket recorded action stamp invalid')
    for k in ('name','group_id','member_id','size_id','signature','scope','definition_id','occurred_on','pool','expires_on','unit_price','total_price','note','reason'):
        if v.get(k) is not None and not isinstance(v[k],str):raise ValueError('Ticket text invalid')
    for k in ('group_id','member_id','size_id','definition_id'):
        if isinstance(v.get(k),str) and not v[k].strip():raise ValueError('Ticket reference invalid')
    for k in ('occurred_on','expires_on'):
        if v.get(k) is not None and (not re.fullmatch(r'\d{4}-\d{2}-\d{2}',v[k]) or datetime.date.fromisoformat(v[k]).isoformat()!=v[k]):raise ValueError('Ticket day invalid')
    for k in ('unit_price','total_price'):
        if v.get(k) is not None:money(v[k])
    q=v.get('quantity')
    if q is not None and (type(q) is not int or q==0 or abs(q)>1000000000):raise ValueError('Ticket quantity invalid')
    for k,values in {'scope':('personal','group'),'pool':('long','dated'),'signature':('unsigned','signed','homework')}.items():
        if v.get(k) is not None and v[k] not in values:raise ValueError('Ticket option invalid')
    if v.get('scope')=='group' and v.get('member_id') is not None:raise ValueError('Group coupon has member')
    if v.get('pool')=='long' and v.get('expires_on') is not None:raise ValueError('Long pool has expiry')
    if v.get('active') is not None and type(v['active']) is not bool:raise ValueError('Ticket active invalid')
    return v

def cost(v):
    u,t,q=v.get('unit_price'),v.get('total_price'),v.get('quantity')
    if u is not None and t is not None and q is not None and money(u)*abs(q)!=money(t):return None
    if t is not None and q is not None:return money(t)/abs(q)
    return None if u is None else money(u)
def entity(r):
    if not isinstance(r['id'],str) or not r['id'] or type(r['seq']) is not int or r['seq']<1 or type(r['revision']) is not int or r['revision']<1 or r['kind'] not in ('definition','purchase','adjustment','setting') or type(r['posted']) is not int or r['posted'] not in (0,1) or any(not action_stamp(r[k]) for k in ('created_at','updated_at')) or r['updated_at']<r['created_at']:raise ValueError('Ticket metadata invalid')
    v=info(r['information_json']);a=json.loads(r['allocations_json'])
    if not isinstance(a,list) or any(not isinstance(x,dict) for x in a):raise ValueError('Ticket allocations invalid')
    if r['kind']=='setting' and v.get('reminder_days') is not None and (type(v['reminder_days']) is not int or not 0<=v['reminder_days']<=365):raise ValueError('Ticket reminder invalid')
    if r['posted']:
        if r['kind'] not in ('purchase','adjustment') or any(v.get(k) is None for k in ('quantity','occurred_on','definition_id','pool')) or (v['pool']=='dated' and v.get('expires_on') is None) or (r['kind']=='purchase' and v['quantity']<0) or (v.get('unit_price') is not None and v.get('total_price') is not None and cost(v) is None):raise ValueError('Posted ticket incomplete/conflicting')
        if v['quantity']>0 and a:raise ValueError('Incoming allocation invalid')
    elif a:raise ValueError('Unposted allocation invalid')
    return v,a

def cost_link_audit(db):
    """Retain and verify schema8 cost-only basis revisions in existing audit rows."""
    histories=table_rows(db,HISTORY,('id','object_id','operation_id','before_json','after_json','created_at'),order='id')
    ops={o['id']:o for o in table_rows(db,OPS,('id','request_json'))}
    by_op={h['operation_id']:h for h in histories}
    revisions={};old_lots=[];new_lots=[]
    for h in histories:
        req=decode_json(ops[h['operation_id']]['request_json'])
        if '__cheki_cost_link_v1' not in req:continue
        tag=req['__cheki_cost_link_v1']
        if not isinstance(tag,dict) or not isinstance(tag.get('root_operation'),str) or h['before_json'] is None:raise ValueError('Cost link audit invalid')
        root=by_op.get(tag['root_operation'])
        if root is None or root['before_json'] is None:raise ValueError('Cost link purchase audit missing')
        rb=decode_row(root['before_json']);ra=decode_row(root['after_json'])
        ib,_=entity(rb);ia,_=entity(ra)
        if rb['kind']!='purchase' or not rb['posted'] or not ra['posted'] or (ib.get('quantity') or 0)<=0 or {k:v for k,v in ib.items() if k not in ('unit_price','total_price')}!={k:v for k,v in ia.items() if k not in ('unit_price','total_price')} or h['created_at']!=root['created_at']:raise ValueError('Cost link is not a purchase money edit')
        before=decode_row(h['before_json']);after=decode_row(h['after_json']);bv,ba=entity(before);av,aa=entity(after)
        if before['kind']!='adjustment' or not before['posted'] or not after['posted'] or before['information_json']!=after['information_json'] or [{k:v for k,v in x.items() if k!='cost'} for x in ba]!=[{k:v for k,v in x.items() if k!='cost'} for x in aa]:raise ValueError('Cost link changed inventory facts')
        b,a=tag.get('before_lot'),tag.get('after_lot')
        if (b is None)!=(a is None):raise ValueError('Cost link basis audit incomplete')
        if b is None:
            if (bv.get('quantity') or 0)>=0:raise ValueError('Cost link incoming basis missing')
            continue
        old=decode_row(b);new=decode_row(a)
        keep=lambda x:{k:v for k,v in x.items() if k not in ('unit_cost','source_unit_cost','source_json')}
        if old.get('ticket_id')!=before['id'] or new.get('ticket_id')!=after['id'] or keep(old)!=keep(new):raise ValueError('Cost link changed lineage')
        rev=revisions.setdefault(before['id'],[])
        if rev and rev[-1][2]!=old:raise ValueError('Cost basis revision chain broken')
        rev.append((after['revision'],old,new));old_lots.append(old);new_lots.append(new)
    if revisions:
        actual={b['ticket_id']:b for b in table_rows(db,'cheki_transfer_lots',('ticket_id',))}
        if any(actual.get(k)!=v[-1][2] for k,v in revisions.items()):raise ValueError('Cost basis current audit mismatch')
    def historical_unit(source,basis):
        rev=revisions.get(source['id'])
        if not rev:return basis['unit_cost']
        value=rev[0][1]['unit_cost']
        for number,_,new in rev:
            if number<=source['revision']:value=new['unit_cost']
        return value
    return old_lots,new_lots,historical_unit

def verify_tickets(db):
    rows=table_rows(db,OBJECTS,FIELDS,order='seq');ops=table_rows(db,OPS,('id','object_id','request_json','result_json','created_at'));hist=table_rows(db,HISTORY,('id','object_id','operation_id','before_json','after_json','created_at'))
    for t in (OBJECTS,OPS,HISTORY):
        if db.execute(f'PRAGMA foreign_key_check({t})').fetchall():raise ValueError('Ticket FK invalid')
    defs={r['id']:r for r in rows if r['kind']=='definition'};parsed={r['id']:entity(r) for r in rows}
    for r in rows:
        v,a=parsed[r['id']]
        for k,t in {'group_id':'cheki_groups','member_id':'cheki_members','size_id':'cheki_sizes','definition_id':OBJECTS}.items():
            if v.get(k) is None:continue
            found=table_rows(db,t,('id',))
            matches=[x for x in found if x['id']==v[k]]
            if len(matches)!=1 or (k=='definition_id' and matches[0]['kind']!='definition') or (k=='member_id' and v.get('group_id') is not None and matches[0]['group_id']!=v['group_id']):raise ValueError('Ticket dangling/inconsistent reference')
        if r['posted']:
            d=info(defs[v['definition_id']]['information_json'])
            if d.get('group_id') is None or d.get('scope') is None or (d['scope']=='personal' and d.get('member_id') is None):raise ValueError('Posted ticket definition incomplete')
    balance={};incoming={}
    inherited={r['ticket_id']: None if r['unit_cost'] is None else Fraction(r['unit_cost']) for r in table_rows(db,'cheki_transfer_lots',('ticket_id','unit_cost'))} if db.execute('PRAGMA user_version').fetchone()[0]>=8 else {}
    units={r['id']:inherited.get(r['id'],cost(parsed[r['id']][0])) for r in rows}
    for r in sorted((r for r in rows if r['posted']),key=lambda r:(parsed[r['id']][0]['occurred_on'],r['seq'])):
        v,a=parsed[r['id']];q=v['quantity']
        if q>0:balance[r['id']]=q;incoming[r['id']]=v
        else:
            total=0
            for x in a:
                n=x.get('quantity');s=incoming.get(x.get('source_id'))
                if type(n) is not int or n<=0 or s is None or any(s.get(k)!=v.get(k) for k in ('definition_id','pool','expires_on')) or balance[x['source_id']]<n or x.get('cost')!=(None if units[x['source_id']] is None else str(units[x['source_id']]*n)):raise ValueError('Ticket inventory/cost allocation inconsistent')
                balance[x['source_id']]-=n;total+=n
            if total!=-q:raise ValueError('Ticket outgoing quantity inconsistent')
    operation={r['id']:r for r in ops};seen=set();latest={}
    for t in ('cheki_catalog_operations','cheki_identity_operations','cheki_record_operations'):
        if any(r[0] in operation for r in db.execute(f'SELECT id FROM {t}')):raise ValueError('Ticket operation collision')
    for h in hist:
        op=operation.get(h['operation_id']);after=decode_row(h['after_json']);entity(after);before=None if h['before_json'] is None else decode_row(h['before_json']);previous=latest.get(h['object_id'])
        if op is None or op['id'] in seen or op['object_id']!=after['id'] or h['object_id']!=after['id'] or op['created_at']!=h['created_at'] or after['updated_at']!=h['created_at'] or op['result_json']!=h['after_json'] or not action_stamp(h['created_at']) or (previous is None and (before is not None or after['revision']!=1)) or (previous is not None and (before!=previous or after['revision']!=previous['revision']+1 or any(before[k]!=after[k] for k in ('seq','created_at','kind')))):raise ValueError('Ticket audit chain invalid')
        req=decode_json(op['request_json'])
        if req.get('kind')!=after['kind'] or req.get('information_json')!=after['information_json'] or req.get('posted')!=bool(after['posted']) or req.get('id')!=(None if before is None else after['id']) or req.get('revision')!=(None if before is None else before['revision']):raise ValueError('Ticket request mismatch')
        latest[after['id']]=after;seen.add(op['id'])
    if len(seen)!=len(ops) or len(latest)!=len(rows) or any(latest.get(r['id'])!=r for r in rows):raise ValueError('Ticket audit incomplete')
    cost_link_audit(db)
    return {OBJECTS:len(rows),OPS:len(ops),HISTORY:len(hist)}
