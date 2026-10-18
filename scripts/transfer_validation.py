"""Read-only schema8 exchange/gift ownership and exact cost lineage checks."""
import datetime
import json
import re
from fractions import Fraction
from catalog_validation import action_stamp, decode_json, decode_row, table_rows
from ticket_validation import entity as ticket_entity, cost, cost_link_audit

OBJECTS='cheki_transfer_objects'; OPS='cheki_transfer_operations'
BINDINGS='cheki_transfer_bindings'; LOTS='cheki_transfer_lots'

def information(value):
    v=decode_json(value)
    for k in ('kind','source_definition_id','source_pool','source_expires_on','target_definition_id','target_pool','target_expires_on','occurred_on','note'):
        if v.get(k) is not None and not isinstance(v[k],str): raise ValueError('Transfer text invalid')
    for k in ('source_definition_id','target_definition_id'):
        if v.get(k) is not None and not v[k].strip():raise ValueError('Transfer reference invalid')
    for k in ('occurred_on','source_expires_on','target_expires_on'):
        if v.get(k) is not None and (not re.fullmatch(r'\d{4}-\d{2}-\d{2}',v[k]) or datetime.date.fromisoformat(v[k]).isoformat()!=v[k]):raise ValueError('Transfer date invalid')
    if v.get('kind') is not None and v['kind'] not in ('exchange','gift'):raise ValueError('Transfer kind invalid')
    if v.get('quantity') is not None and (type(v['quantity']) is not int or not 0<v['quantity']<=1000000000):raise ValueError('Transfer quantity invalid')
    if v.get('allow_expired') is not None and type(v['allow_expired']) is not bool:raise ValueError('Transfer expired consent invalid')
    for side in ('source','target'):
        if v.get(side+'_pool') is not None and v[side+'_pool'] not in ('long','dated'):raise ValueError('Transfer pool invalid')
        if v.get(side+'_pool')=='long' and v.get(side+'_expires_on') is not None:raise ValueError('Transfer long pool expiry invalid')
    return v

def entity(r,definitions):
    if not isinstance(r['id'],str) or not r['id'] or type(r['seq']) is not int or r['seq']<1 or type(r['revision']) is not int or r['revision']<1 or type(r['posted']) is not int or r['posted'] not in (0,1) or any(not action_stamp(r[k]) for k in ('created_at','updated_at')) or r['updated_at']<r['created_at']:raise ValueError('Transfer metadata invalid')
    v=information(r['information_json']);children=json.loads(r['children_json'])
    if not isinstance(children,list) or any(not isinstance(x,str) or not x for x in children) or len(set(children))!=len(children):raise ValueError('Transfer children invalid')
    for side in ('source','target'):
        if v.get(side+'_definition_id') is not None and v[side+'_definition_id'] not in definitions:raise ValueError('Transfer definition missing')
    if r['posted']:
        if any(v.get(k) is None for k in ('kind','quantity','occurred_on','source_definition_id','source_pool')) or v['source_pool']=='dated' and v.get('source_expires_on') is None:raise ValueError('Transfer posted source incomplete')
        if v['kind']=='exchange':
            if any(v.get(k) is None for k in ('target_definition_id','target_pool')) or v['target_pool']=='dated' and v.get('target_expires_on') is None:raise ValueError('Transfer posted target incomplete')
            if all(v.get('source_'+k)==v.get('target_'+k) for k in ('definition_id','pool','expires_on')):raise ValueError('Transfer no-op invalid')
        if v.get('source_expires_on') is not None and v['source_expires_on']<v['occurred_on'] and v.get('allow_expired') is not True:raise ValueError('Transfer expired consent missing')
    return v,children

def matching(r,children,definitions):
    v,ids=entity(r,definitions)
    if len(children)!=len(ids) or {c['id'] for c in children}!=set(ids):raise ValueError('Transfer child snapshots inconsistent')
    if not r['posted']:
        if children:raise ValueError('Transfer draft changed stock')
        return
    outgoing=incoming=0
    for c in children:
        info,_=ticket_entity(c);q=info.get('quantity')
        if c['kind']!='adjustment' or not c['posted'] or q is None or info.get('transfer_id')!=r['id'] or info.get('occurred_on')!=v['occurred_on']:raise ValueError('Transfer child state invalid')
        side='source' if q<0 else 'target'
        if any(info.get(k)!=v.get(side+'_'+k) for k in ('definition_id','pool','expires_on')):raise ValueError('Transfer child pool invalid')
        if q<0:outgoing-=q
        else:incoming+=q
    if outgoing!=v['quantity'] or incoming!=(v['quantity'] if v['kind']=='exchange' else 0):raise ValueError('Transfer quantity not conserved')

def exact(text):
    if text is None:return None
    if not isinstance(text,str) or len(text)>200 or not re.fullmatch(r'\d+(?:/[1-9]\d*)?',text):raise ValueError('Transfer exact cost invalid')
    v=Fraction(text)
    if str(v)!=text:raise ValueError('Transfer cost is not canonical')
    return v

def verify_transfers(db):
    tables=(OBJECTS,OPS,BINDINGS,LOTS)
    for t in tables:
        if db.execute(f'PRAGMA foreign_key_check({t})').fetchall():raise ValueError('Transfer FK invalid')
    rows=table_rows(db,OBJECTS,('seq','id','information_json','children_json','posted','revision','created_at','updated_at'),order='seq')
    ops=table_rows(db,OPS,('seq','id','object_id','request_json','before_json','result_json','created_at'),order='seq')
    tickets={r['id']:r for r in table_rows(db,'cheki_ticket_objects',('id',))}
    defs={k for k,r in tickets.items() if r['kind']=='definition'}
    histories={}
    for h in table_rows(db,'cheki_ticket_history',('object_id','after_json')):histories.setdefault(h['object_id'],[]).append(decode_row(h['after_json']))
    ids={r['id'] for r in ops}
    for t in ('cheki_catalog_operations','cheki_identity_operations','cheki_record_operations','cheki_ticket_operations','cheki_entry_operations'):
        if any(r[0] in ids for r in db.execute(f'SELECT id FROM {t}')):raise ValueError('Transfer operation collision')
    latest={};bound={}
    for op in ops:
        if not isinstance(op['id'],str) or not op['id'] or not action_stamp(op['created_at']):raise ValueError('Transfer action invalid')
        result=decode_json(op['result_json']);r=decode_row(result['object_json']);entity(r,defs)
        before=None if op['before_json'] is None else decode_row(op['before_json']);prev=latest.get(r['id']);req=decode_json(op['request_json'])
        if op['object_id']!=r['id'] or r['updated_at']!=op['created_at'] or (prev is None and (before is not None or r['revision']!=1)) or (prev is not None and (before!=prev or r['revision']!=prev['revision']+1 or any(r[k]!=prev[k] for k in ('seq','created_at')))) or req.get('id')!=(None if before is None else r['id']) or req.get('revision')!=(None if before is None else before['revision']) or req.get('information_json')!=r['information_json'] or type(req.get('posted')) is not bool or req['posted']!=bool(r['posted']):raise ValueError('Transfer audit chain invalid')
        children=[decode_row(c) for c in json.loads(result['children_json'])];matching(r,children,defs)
        for child in children:
            if child not in histories.get(child['id'],[]) or bound.get(child['id'],r['id'])!=r['id']:raise ValueError('Transfer child original missing')
            bound[child['id']]=r['id']
        latest[r['id']]=r
    current=set()
    if len(latest)!=len(rows):raise ValueError('Transfer audit incomplete')
    for r in rows:
        if latest.get(r['id'])!=r:raise ValueError('Transfer current revision mismatch')
        _,children=entity(r,defs)
        if any(c in current or c not in tickets for c in children):raise ValueError('Transfer current children invalid')
        matching(r,[tickets[c] for c in children],defs);current.update(children)
    links=table_rows(db,BINDINGS,('ticket_id','transfer_id'))
    if len(links)!=len(bound) or any(bound.get(b['ticket_id'])!=b['transfer_id'] or tickets[b['ticket_id']]['posted'] and b['ticket_id'] not in current for b in links):raise ValueError('Transfer child changed alone')
    bases=table_rows(db,LOTS,('ticket_id','source_id','outgoing_id','quantity','unit_cost','source_json','source_unit_cost','created_at'))
    byIncoming={r['ticket_id']:r for r in bases};covered=set()
    old_lots,new_lots,historical_unit=cost_link_audit(db)
    for b in [*bases,*old_lots,*new_lots]:
        incoming=tickets.get(b['ticket_id']);outgoing=tickets.get(b['outgoing_id']);source=decode_row(b['source_json']);sv,_=ticket_entity(source)
        if incoming is None or outgoing is None or incoming['id'] not in bound or bound[incoming['id']]!=bound.get(outgoing['id']) or type(b['quantity']) is not int or b['quantity']<=0 or ticket_entity(incoming)[0].get('quantity')!=b['quantity'] or not action_stamp(b['created_at']) or source['id']!=b['source_id'] or (sv.get('quantity') or 0)<=0 or source['seq']>=incoming['seq'] or source not in histories.get(source['id'],[]):raise ValueError('Transfer original cost lot invalid')
        unit=exact(b['unit_cost']);basis=byIncoming.get(source['id']);expected=cost(sv) if basis is None else exact(historical_unit(source,basis))
        if unit!=expected or b['source_unit_cost']!=b['unit_cost']:raise ValueError('Transfer inherited cost changed')
        if not any(old['posted'] and any(a.get('source_id')==source['id'] and a.get('quantity')==b['quantity'] and a.get('cost')==(None if unit is None else str(unit*b['quantity'])) for a in ticket_entity(old)[1]) for old in histories.get(outgoing['id'],[])):raise ValueError('Transfer outgoing allocation differs')
        covered.add(incoming['id'])
    if any(ticket_entity(tickets[k])[0]['quantity']>0 and k not in covered for k in bound):raise ValueError('Transfer incoming lineage missing')
    for outgoing in {b['outgoing_id'] for b in bases}:
        parts=[b for b in bases if b['outgoing_id']==outgoing]
        if not any(old['posted'] and len(ticket_entity(old)[1])==len(parts) and all(sum(1 for b in parts if b['source_id']==a.get('source_id') and b['quantity']==a.get('quantity') and a.get('cost')==(None if b['unit_cost'] is None else str(exact(b['unit_cost'])*b['quantity'])))==1 for a in ticket_entity(old)[1]) for old in histories.get(outgoing,[])):raise ValueError('Transfer per-source coverage differs')
    return {OBJECTS:len(rows),OPS:len(ops),BINDINGS:len(links),LOTS:len(bases)}
