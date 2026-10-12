"""Read-only nullable record and revision checks; no inferred historical defaults."""
import datetime
import re
from catalog_validation import action_stamp, decode_json, decode_row, table_rows

RECORDS='cheki_records'
OPS='cheki_record_operations'
HISTORY='cheki_record_history'

def information(raw):
    data=decode_json(raw)
    for k in ('occurred_on','size_id','note'):
        if data.get(k) is not None and not isinstance(data[k],str):raise ValueError('Record text type invalid')
    day=data.get('occurred_on')
    if day is not None:
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}',day) or datetime.date.fromisoformat(day).isoformat()!=day:raise ValueError('Record day invalid')
    if data.get('size_id') is not None and not data['size_id'].strip():raise ValueError('Record size invalid')
    q=data.get('quantity')
    if q is not None and (type(q) is not int or q<=0):raise ValueError('Known quantity invalid')
    ids=data.get('member_ids')
    if ids is not None and (not isinstance(ids,list) or any(not isinstance(i,str) or not i.strip() for i in ids) or len(set(ids))!=len(ids)):raise ValueError('Record members invalid')
    attributes=data.get('attributes')
    if attributes is not None:
        if not isinstance(attributes,dict) or (attributes.get('kind') is not None and attributes['kind'] not in ('unsigned','signed','homework')) or (attributes.get('back_signed') is not None and type(attributes['back_signed']) is not bool) or (attributes.get('back_signed') is True and attributes.get('kind')!='signed'):raise ValueError('Record attributes invalid')
    hint=data.get('receipt_status_hint')
    if hint is not None and hint not in ('received','partial','unreceived'):raise ValueError('Record receipt hint invalid')
    batches=data.get('receipt_batches')
    if batches is not None:
        if not isinstance(batches,list):raise ValueError('Receipt batches invalid')
        total=0; known=True
        for b in batches:
            if not isinstance(b,dict) or (b.get('quantity') is not None and (type(b['quantity']) is not int or b['quantity']<=0)) or (b.get('origin') is not None and b['origin'] not in ('initial','actual','legacyUnknown')):raise ValueError('Receipt batch invalid')
            if b.get('quantity') is None:known=False
            else:total+=b['quantity']
            stamp=b.get('received_at')
            if stamp is not None:
                if not isinstance(stamp,str) or b.get('origin')=='initial' or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z',stamp):raise ValueError('Receipt time invalid')
                dt=datetime.datetime.fromisoformat(stamp.replace('Z','+00:00'))
                if dt.isoformat(timespec='milliseconds' if len(stamp)==24 else 'microseconds').replace('+00:00','Z')!=stamp:raise ValueError('Receipt time normalized unexpectedly')
                if day is not None and (dt+datetime.timedelta(hours=8)).date().isoformat()<day:raise ValueError('Receipt predates occurrence')
        if q is not None and total>q:raise ValueError('Over-receipt')
        if known and total==0 and hint in ('received','partial'):raise ValueError('Receipt status conflicts with known zero received')
        initial=[b for b in batches if b.get('origin')=='initial']
        if initial and (len(initial)!=1 or len(batches)!=1 or hint not in (None,'received') or (q is not None and initial[0].get('quantity') is not None and initial[0]['quantity']!=q)):raise ValueError('Initial receipt invalid')
        if known and q is not None and hint is not None and hint!=('unreceived' if total==0 else 'received' if total==q else 'partial'):raise ValueError('Receipt hint inconsistent')
    if data.get('cost_reference') is not None:raise ValueError('M1 cost allocation unavailable')
    return data

def record(row):
    if not isinstance(row.get('id'),str) or not row['id'].strip() or type(row.get('revision')) is not int or row['revision']<1 or any(not action_stamp(row.get(k)) for k in ('created_at','updated_at')) or row['updated_at']<row['created_at']:raise ValueError('Record metadata invalid')
    return information(row['information_json'])

def verify_records(db):
    rows=table_rows(db,RECORDS,('id','information_json','created_at','updated_at','revision'))
    ops=table_rows(db,OPS,('id','record_id','request_json','result_json','created_at'))
    histories=table_rows(db,HISTORY,('id','record_id','operation_id','before_json','after_json','created_at'))
    for table in (RECORDS,OPS,HISTORY):
        if db.execute(f'PRAGMA foreign_key_check({table})').fetchall():raise ValueError('Record FK violation')
    op_map={r['id']:r for r in ops};seen=set();last={}
    for table in ('cheki_catalog_operations','cheki_identity_operations'):
        if set(op_map)&{r[0] for r in db.execute(f'SELECT id FROM {table}')}:raise ValueError('Record operation ID reused')
    member_rows=table_rows(db,'cheki_members',('id','person_id'))
    members={r['id']:r for r in member_rows};sizes={r[0] for r in db.execute('SELECT id FROM cheki_sizes')}
    def refs(info,current=False):
        ids=info.get('member_ids') or []
        if not set(ids)<=members.keys() or (info.get('size_id') is not None and info['size_id'] not in sizes):raise ValueError('Record dangling reference')
        if current:
            linked=[members[i]['person_id'] for i in ids if members[i]['person_id'] is not None]
            if len(linked)!=len(set(linked)):raise ValueError('Record same Person duplicate')
    for h in histories:
        op=op_map.get(h['operation_id'])
        if op is None or type(h['id']) is not int or h['id']<=0 or not isinstance(op['id'],str) or not op['id'].strip() or op['id'] in seen or op['record_id']!=h['record_id'] or op['created_at']!=h['created_at'] or not action_stamp(h['created_at']):raise ValueError('Record history relationship invalid')
        seen.add(op['id']);after=decode_row(h['after_json']);info=record(after);before=None if h['before_json'] is None else decode_row(h['before_json']);request=decode_json(op['request_json'])
        if after['id']!=h['record_id'] or after!=decode_row(op['result_json']) or after['updated_at']!=h['created_at'] or request.get('information_json')!=after['information_json']:raise ValueError('Record request/result mismatch')
        if before is None:
            if after['id'] in last or after['revision']!=1 or after['created_at']!=after['updated_at'] or request.get('id') is not None or request.get('revision') is not None:raise ValueError('Record creation invalid')
        else:
            record(before)
            preserved=set(before)-{'information_json','updated_at','revision'}
            if last.get(after['id'])!=before or set(after)-{'information_json','updated_at','revision'}!=preserved or any(after[k]!=before[k] for k in preserved) or after['revision']!=before['revision']+1 or after['updated_at']<before['updated_at'] or request.get('id')!=before['id'] or type(request.get('revision')) is not int or request['revision']!=before['revision']:raise ValueError('Record revision chain invalid')
        refs(info);last[after['id']]=after
    if len(seen)!=len(ops) or len(rows)!=len(last):raise ValueError('Record audit missing')
    for r in rows:
        info=record(r);refs(info,current=True)
        if last.get(r['id'])!=r:raise ValueError('Record current/history mismatch')
    return {RECORDS:len(rows),OPS:len(ops),HISTORY:len(histories)}
