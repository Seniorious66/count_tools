"""Read-only schema7 compound record/coupon operation and immutable binding checks."""
import json
import re
from collections import Counter
from catalog_validation import action_stamp,decode_json,decode_row,table_rows
from record_validation import information
from ticket_validation import info as ticket_info
STATES='cheki_entry_states';OPS='cheki_entry_operations';BINDINGS='cheki_entry_ticket_bindings'
def plan(raw):
    v=decode_json(raw)
    if v.get('mode') not in (None,'consume','record_only'):raise ValueError('Use mode invalid')
    origin=v.get('expense_origin')
    if origin not in (None,'direct','coupons') or (origin=='direct' and v.get('mode')!='record_only') or (origin=='coupons' and v.get('mode')!='consume') or ('direct_amount' in v and origin!='direct'):raise ValueError('Expense source invalid')
    amount=v.get('direct_amount')
    if amount is not None and (not isinstance(amount,str) or len(amount)>80 or not re.fullmatch(r'\d+(?:\.\d+)?',amount)):raise ValueError('Direct amount invalid')
    if v.get('lines') is not None and not isinstance(v['lines'],list):raise ValueError('Use lines invalid')
    for line in v.get('lines') or []:
        if not isinstance(line,dict):raise ValueError('Use line invalid')
        for k in ('member_id','definition_id','member_name','definition_name','group_name'):
            if line.get(k) is not None and (not isinstance(line[k],str) or (k.endswith('_id') and not line[k])):raise ValueError('Use reference invalid')
        q=line.get('quantity')
        if q is not None and (type(q) is not int or q<=0 or q>1000000000):raise ValueError('Use quantity invalid')
        if line.get('pools') is not None and not isinstance(line['pools'],list):raise ValueError('Use pools invalid')
        keys=set()
        for p in line.get('pools') or []:
            if not isinstance(p,dict) or p.get('pool') not in (None,'long','dated'):raise ValueError('Use pool invalid')
            if p.get('expires_on') is not None:ticket_info(json.dumps({'expires_on':p['expires_on']}))
            if p.get('pool')=='long' and p.get('expires_on') is not None:raise ValueError('Long use has expiry')
            n=p.get('quantity')
            if n is not None and (type(n) is not int or n<0 or n>1000000000):raise ValueError('Use pool quantity invalid')
            if p.get('allow_expired') is not None and type(p['allow_expired']) is not bool:raise ValueError('Expired confirmation invalid')
            if p.get('pool') is not None:
                key=(p['pool'],p.get('expires_on'))
                if key in keys:raise ValueError('Duplicate use pool')
                keys.add(key)
    return v

def validate_plan(db,info,p,actual=False,historical=False):
    if actual and (info.get('quantity') is None or info.get('occurred_on') is None or not info.get('member_ids') or not p.get('lines')):raise ValueError('Actual use incomplete')
    for l in p.get('lines') or []:
        member,definition=l.get('member_id'),l.get('definition_id');m=d=None
        if member is not None:
            members=table_rows(db,'cheki_members',('id','group_id'));matches=[x for x in members if x['id']==member]
            if len(matches)!=1 or (info.get('member_ids') is not None and member not in info['member_ids']):raise ValueError('Use member differs from record')
            m=matches[0]
        if definition is not None:
            rows=table_rows(db,'cheki_ticket_objects',('id','kind','information_json'));matches=[x for x in rows if x['id']==definition and x['kind']=='definition']
            if len(matches)!=1:raise ValueError('Use definition missing')
            d=ticket_info(matches[0]['information_json'])
        if actual:
            if not historical and (m is None or d is None or d.get('group_id') is None or d['group_id']!=m['group_id'] or d.get('scope') not in ('personal','group') or (d['scope']=='personal' and d.get('member_id')!=member)):raise ValueError('Use ownership inconsistent')
            wanted=l.get('quantity');pools=l.get('pools') or []
            if type(wanted) is not int or wanted<=0 or not pools:raise ValueError('Use quantity not complete')
            if any(type(x.get('quantity')) is not int or x.get('pool') is None or (x['pool']=='dated' and x.get('expires_on') is None) for x in pools) or sum(x['quantity'] for x in pools)!=wanted:raise ValueError('Use allocation differs from demand')

def consumption(info,p,children):
    expected=Counter();actual=Counter()
    if p.get('mode')=='consume':
        for l in p.get('lines') or []:
            for x in l.get('pools') or []:
                n=x.get('quantity')
                if n==0:continue
                if type(n) is not int or n<0:raise ValueError('Actual pool unknown')
                expected[(l.get('member_id'),l.get('definition_id'),x.get('pool'),x.get('expires_on'))]+=n
    for r in children:
        v=ticket_info(r['information_json'])
        if r['posted']!=1 or type(v.get('quantity')) is not int or v['quantity']>=0 or v.get('occurred_on')!=info.get('occurred_on'):raise ValueError('Use date or quantity changed independently')
        actual[(v.get('member_id'),v.get('definition_id'),v.get('pool'),v.get('expires_on'))]-=v['quantity']
    if expected!=actual:raise ValueError('Actual use differs from reviewed pools')

def state(row):
    if not isinstance(row.get('record_id'),str) or not isinstance(row.get('operation_id'),str) or type(row.get('record_revision')) is not int or row['record_revision']<1:raise ValueError('Entry metadata invalid')
    p=plan(row['plan_json']);children=json.loads(row['children_json'])
    if not isinstance(children,list) or any(not isinstance(x,str) for x in children) or len(set(children))!=len(children):raise ValueError('Entry child identity invalid')
    return p,children

def verify_entries(db):
    states=table_rows(db,STATES,('record_id','operation_id','plan_json','children_json','record_revision'),order='record_id')
    ops=table_rows(db,OPS,('seq','id','record_id','request_json','result_json','created_at'),order='seq')
    bindings=table_rows(db,BINDINGS,('ticket_id','record_id'),order='ticket_id')
    for t in (STATES,OPS,BINDINGS):
        if db.execute(f'PRAGMA foreign_key_check({t})').fetchall():raise ValueError('Entry FK invalid')
    global_ids={r['id'] for r in ops}
    for t in ('cheki_catalog_operations','cheki_identity_operations','cheki_record_operations','cheki_ticket_operations'):
        if global_ids&{r[0] for r in db.execute(f'SELECT id FROM {t}')}:raise ValueError('Entry operation ID collision')
    records={r['id']:r for r in table_rows(db,'cheki_records',('id','revision','information_json'))}
    record_ops={r['id']:r for r in table_rows(db,'cheki_record_operations',('id','request_json','result_json'))}
    histories=table_rows(db,'cheki_ticket_history',('object_id','after_json'))
    ticket_rows={r['id']:r for r in table_rows(db,'cheki_ticket_objects',('id','posted','information_json'))}
    latest={};used={}
    for op in ops:
        if not isinstance(op['id'],str) or not op['id'] or not action_stamp(op['created_at']):raise ValueError('Entry action invalid')
        result=decode_json(op['result_json']);after=decode_row(result['state_json']);before=None if result.get('before_state_json') is None else decode_row(result['before_state_json']);record=decode_row(result['record_json']);p,ids=state(after);req=decode_json(op['request_json']);r_op=record_ops.get(op['id']+':record')
        if after['record_id']!=record['id'] or after['operation_id']!=op['id'] or op['record_id']!=record['id'] or after['record_revision']!=record['revision'] or req.get('information_json')!=record['information_json'] or req.get('plan_json')!=after['plan_json'] or r_op is None or decode_row(r_op['result_json'])!=record or record['updated_at']!=op['created_at'] or before!=latest.get(record['id']):raise ValueError('Entry operation or immutable revision invalid')
        values=json.loads(result['children_json'])
        if not isinstance(values,list):raise ValueError('Entry children invalid')
        children=[decode_row(x) for x in values]
        if len(children)!=len(ids) or len({x['id'] for x in children})!=len(children):raise ValueError('Duplicate entry child')
        for child in children:
            v=ticket_info(child['information_json']);id=child['id']
            if id not in ids or child['posted']!=1 or child['kind']!='adjustment' or v.get('linked_record_id')!=record['id'] or (id in used and used[id]!=record['id']) or not any(h['object_id']==id and decode_row(h['after_json'])==child for h in histories):raise ValueError('Immutable coupon child binding invalid')
            used[id]=record['id']
        information(record['information_json']);validate_plan(db,json.loads(record['information_json']),p,actual=p.get('mode')=='consume',historical=True);consumption(json.loads(record['information_json']),p,children);latest[record['id']]=after
    if len(states)!=len(latest):raise ValueError('Entry current state missing')
    current_children=set()
    for s in states:
        p,ids=state(s);r=records.get(s['record_id'])
        if latest.get(s['record_id'])!=s or r is None or r['revision']!=s['record_revision']:raise ValueError('Record and entry revision differ')
        children=[]
        for id in ids:
            if id in current_children or id not in ticket_rows or ticket_rows[id]['posted']!=1:raise ValueError('Current child missing/duplicate/unposted')
            children.append(ticket_rows[id]);current_children.add(id)
        if json.loads(r['information_json']).get('voided') is not None and (p.get('mode')!='record_only' or ids):raise ValueError('Voided record still consumes')
        consumption(json.loads(r['information_json']),p,children)
    if any(json.loads(r['information_json']).get('voided') is not None and id not in latest for id,r in records.items()):raise ValueError('Void missing entry audit')
    if len(bindings)!=len(used):raise ValueError('Coupon bindings missing')
    for b in bindings:
        id=b['ticket_id']
        if used.get(id)!=b['record_id'] or (ticket_rows[id]['posted']==1 and id not in current_children):raise ValueError('Coupon orphan or binding invalid')
    return {STATES:len(states),OPS:len(ops),BINDINGS:len(bindings)}
