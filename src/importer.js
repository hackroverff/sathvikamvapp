import * as XLSX from 'xlsx';

export const IMPORT_FIELDS = [
  {key:'barcode', label:'Barcode / item code', aliases:['barcode','item code','itemcode','ean','ean code','upc','product code']},
  {key:'name', label:'Product name', aliases:['product name','name','item','item name','description']},
  {key:'category', label:'Category', aliases:['category','product category','group']},
  {key:'mrp', label:'MRP (printed pack price)', aliases:['mrp','printed mrp','mrp printed','mrp value','printed price','printed pack price','maximum retail price']},
  {key:'selling_price', label:'Selling price', aliases:['selling price per piece','selling price per unit','selling price','sellingprice','selling_price','sell price','sale price','sales price','selling rate','sell rate','rate','unit price','price','retail price','our price']},
  {key:'mfg_date', label:'Made date', aliases:['manf date','manf. date','mfg date','manufacturing date','manufacture date','mfg_date','mfd','made date']},
  {key:'expiry_date', label:'Expiry date', aliases:['exp date','expiry date','expiration date','expiry','exp_date','best before']},
  {key:'units', label:'Quantity / units', aliases:['unit (this is quantity)','units','unit','qty','quantity','stock','closing stock','balance']},
];
const normalize = value => String(value ?? '').toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/g,'');
const empty = value => value === null || value === undefined || String(value).trim() === '';

function cellText(sheet, rowIndex, colIndex) {
  const address = XLSX.utils.encode_cell({r:rowIndex,c:colIndex});
  const cell = sheet[address];
  if (!cell || cell.v == null) return '';
  // Keep zero-padded numeric barcode formats and use the exact numeric value otherwise.
  if (typeof cell.v === 'number' && /^0{8,14}$/.test(cell.z || '') && Number.isInteger(cell.v)) return String(cell.v).padStart(cell.z.length,'0');
  return cell.v;
}
function headerMapping(headers) {
  const mapping = {};
  for (const field of IMPORT_FIELDS) {
    const aliases = new Set(field.aliases.map(normalize));
    const exact = headers.findIndex(h => aliases.has(normalize(h)));
    if (exact >= 0) mapping[field.key] = exact;
  }
  return mapping;
}

export async function readStockFile(file) {
  const buffer = await file.arrayBuffer();
  const workbook = XLSX.read(buffer, {type:'array', cellDates:true, raw:true, dense:false});
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  if (!sheet || !sheet['!ref']) throw new Error('The file has no readable rows.');
  const range = XLSX.utils.decode_range(sheet['!ref']);
  const rows = [];
  for (let r=range.s.r; r<=range.e.r; r++) {
    const row=[];
    for(let c=range.s.c;c<=range.e.c;c++) row.push(cellText(sheet,r,c));
    rows.push(row);
  }
  let headerIndex=-1, mapping={};
  for (let r=0;r<Math.min(rows.length,50);r++) {
    const candidate=headerMapping(rows[r]);
    const score=Object.keys(candidate).length;
    // A likely header has at least two recognized labels; strongest match wins, titles are ignored.
    if(score>=2 && (headerIndex<0 || score>Object.keys(mapping).length)) {headerIndex=r;mapping=candidate;}
  }
  if(headerIndex<0) throw new Error('I could not find a header row. Choose a sheet with column headings such as Product Name, MRP and Quantity.');
  const headers=rows[headerIndex].map((v,i)=>empty(v)?`Column ${i+1}`:String(v));
  const records=[]; let skipped=0;
  for(let r=headerIndex+1;r<rows.length;r++) {
    const values=rows[r];
    if(values.every(empty)){skipped++;continue;}
    if(Object.values(headerMapping(values)).length>=3){skipped++;continue;}
    records.push({sourceRow:r+1, values});
  }
  return {headers, rows:records, mapping, skipped, sheetName:workbook.SheetNames[0], date1904:!!workbook.Workbook?.WBProps?.date1904};
}

export function parseImportedDate(value, date1904=false) {
  if (empty(value)) return '';
  if (value instanceof Date && !Number.isNaN(value.valueOf())) return isoDate(value);
  if (typeof value === 'number' && Number.isFinite(value)) {
    const d=XLSX.SSF.parse_date_code(value,{date1904});
    if(d) return `${d.y}-${String(d.m).padStart(2,'0')}-${String(d.d).padStart(2,'0')}`;
  }
  const s=String(value).trim();
  if(/^\d{5}(?:\.\d+)?$/.test(s)){const serial=Number(s);if(serial>=20000&&serial<=90000){const d=XLSX.SSF.parse_date_code(serial,{date1904});if(d)return `${d.y}-${String(d.m).padStart(2,'0')}-${String(d.d).padStart(2,'0')}`}}
  let m=s.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T].*)?$/);
  if(m) return validDate(+m[1],+m[2],+m[3]);
  m=s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/);
  if(m) return validDate(+m[3],+m[2],+m[1]);
  const d=new Date(s);
  return Number.isNaN(d.valueOf())?'':isoDate(d);
}
function validDate(y,m,d){const v=new Date(Date.UTC(y,m-1,d));return v.getUTCFullYear()===y&&v.getUTCMonth()===m-1&&v.getUTCDate()===d?`${y}-${String(m).padStart(2,'0')}-${String(d).padStart(2,'0')}`:''}
function isoDate(d){return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`}
export function barcodeText(value) {
  if(empty(value)) return '';
  let s=String(value).trim().replace(/\s/g,'');
  const sci=s.match(/^([+-]?\d+)(?:\.(\d*))?[eE]([+-]?\d+)$/);
  if(sci){const sign=sci[1].startsWith('-')?'-':'';const integer=sci[1].replace(/^[+-]/,'');const digits=integer+(sci[2]||'');const shift=Number(sci[3])-(sci[2]||'').length;if(shift>=0)s=sign+digits+'0'.repeat(Math.min(shift,30));else s=sign+digits.slice(0,Math.max(1,digits.length+shift))}
  if(/^\d+\.0+$/.test(s)) s=s.split('.')[0];
  return s;
}
export function mappedRecord(record, mapping, date1904=false) {
  const get=key=>mapping[key]===undefined?'':record.values[mapping[key]];
  const amount=value=>Number(String(value??'').replace(/[₹,\s]/g,''))||0;
  const mrpColumn=mapping.mrp!==undefined, sellingColumn=mapping.selling_price!==undefined;
  const rawMrp=amount(get('mrp')), rawSelling=amount(get('selling_price'));
  const mrp=rawMrp===0?rawSelling:rawMrp;
  const selling_price=rawSelling===0?mrp:rawSelling;
  return {
    ...record,
    barcode:barcodeText(get('barcode')),
    name:String(get('name')??'').trim(),
    category:String(get('category')??'').trim()||'General',
    mrp,
    selling_price,
    mrp_confirmed:mrpColumn&&sellingColumn&&rawMrp>0&&rawSelling>0,
    mfg_date:parseImportedDate(get('mfg_date'),date1904),
    expiry_date:parseImportedDate(get('expiry_date'),date1904),
    units:Number(String(get('units')??'').replace(/[,\s]/g,''))||0,
  };
}
export function csvTemplate(){return 'barcode,name,category,mrp,selling_price,mfg_date,expiry_date,units\n'}
export function workbookTemplate(){const wb=XLSX.utils.book_new();const ws=XLSX.utils.aoa_to_sheet([['barcode','name','category','mrp','selling_price','mfg_date','expiry_date','units']]);XLSX.utils.book_append_sheet(wb,ws,'Stock template');return wb}
