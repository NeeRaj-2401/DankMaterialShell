.pragma library

// --- D-Bus helpers ----------------------------------------------------------
function parseOpenCalendar(raw) {
  // Expected formats:
  // ('/org/gnome/evolution/dataserver/Subprocess/122783/11', 'org.gnome.evolution.dataserver.Calendar8')
  // (objectpath '/obj', 'org.gnome.evolution.dataserver.Calendar8.Instance-1', 'org.gnome.evolution.dataserver.Calendar8')
  const mPath = raw.match(/'(\/[^']+)'/)
  const mBus  = raw.match(/, '([^']+)'/)
  if (!mPath || !mBus) return null
  return { objectPath: mPath[1], bus: mBus[1] }
}

function extractCalendarSources(raw) {
  // Grep UIDs that have a [Calendar] section nearby
  const text = raw.replace(/, /g, "\n")
  const uids = []
  const regex = /UID.*<'([a-f0-9]{32,40})'>/g
  let match
  while ((match = regex.exec(text)) !== null) {
    uids.push(match[1])
  }
  const unique = Array.from(new Set(uids))
  const result = []
  unique.forEach(uid => {
    const idx = text.indexOf(uid)
    if (idx < 0) return
    const chunk = text.slice(Math.max(0, idx - 2500), idx + 5000)
    if (chunk.indexOf("[Calendar]") >= 0) result.push(uid)
  })
  if (result.indexOf("system-calendar") < 0) result.push("system-calendar")
  return Array.from(new Set(result))
}

function extractCalendarMeta(raw, uids) {
  const text = raw.replace(/, /g, "\n")
  return uids.map(uid => {
    const idx = text.indexOf(uid)
    let display = ""
    let backend = "unknown"
    if (idx >= 0) {
      const chunk = text.slice(Math.max(0, idx - 2500), idx + 5000)
      const dataMatch = chunk.match(/Data.*<'([^']+)'>/)
      if (dataMatch) {
        const data = dataMatch[1].replace(/\\n/g, "\n")
        const dn = (data.match(/^DisplayName=(.+)$/m) || [])[1]
        if (dn) display = dn
        const calSection = data.split(/\n\[Calendar\]\n/)[1] || ""
        const backendName = (calSection.match(/^BackendName=(.+)$/m) || [])[1]
        if (backendName) {
          if (backendName === "local") backend = "local"
          else if (backendName === "caldav") {
            backend = data.indexOf("Parent=f573c08fa5e0706a96f6539b4c3240995be086ea") >= 0 ? "google" : "caldav"
          } else backend = backendName
        }
      }
    }
    if (!display) display = "Calendar " + uid
    return { uid: uid, name: display, backend: backend, enabled: true }
  })
}

function extractVEVENTs(raw) {
  const out = []
  const re = /'([^']*BEGIN:VEVENT[^']*END:VEVENT[^']*)'/g
  let m
  while ((m = re.exec(raw)) !== null) out.push(m[1].replace(/\\n/g, "\n"))
  return out
}

// --- Date helpers -----------------------------------------------------------
function _pad2(n){ return (n<10?"0":"")+n }
function toQueryUtc(dt) {
  const d = new Date(dt)
  return d.getUTCFullYear().toString()
    + _pad2(d.getUTCMonth()+1) + _pad2(d.getUTCDate())
    + "T" + _pad2(d.getUTCHours()) + _pad2(d.getUTCMinutes()) + _pad2(d.getUTCSeconds()) + "Z"
}
function nowUtcStamp() {
  const d = new Date()
  return d.getUTCFullYear().toString()
    + _pad2(d.getUTCMonth()+1) + _pad2(d.getUTCDate())
    + "T" + _pad2(d.getUTCHours()) + _pad2(d.getUTCMinutes()) + _pad2(d.getUTCSeconds()) + "Z"
}
function plusHour(s){ return new Date(new Date(s).getTime()+3600000).toISOString() }
function windowStart(s){ return new Date(new Date(s).getTime()-900000).toISOString() }
function windowEnd(s){ return new Date(new Date(s).getTime()+900000).toISOString() }

// --- ICS helpers ------------------------------------------------------------
function _kv(line){ const i=line.indexOf(":"); return i<0?{key:line,value:""}:{key:line.slice(0,i),value:line.slice(i+1)} }
function _parseDt(v){
  if (/^\d{8}$/.test(v)) return { iso: v.slice(0,4)+"-"+v.slice(4,6)+"-"+v.slice(6,8), allDay:true }
  if (/^\d{8}T\d{6}Z?$/.test(v)) {
    const y=v.slice(0,4), m=v.slice(4,6), d=v.slice(6,8), hh=v.slice(9,11), mi=v.slice(11,13), ss=v.slice(13,15)
    const z=v.endsWith("Z")?"Z":""; return { iso:`${y}-${m}-${d}T${hh}:${mi}:${ss}${z}`, allDay:false }
  }
  return { iso:v, allDay:false }
}
function parseEvent(ics) {
  const lines = ics.split(/\r?\n/)
  const ev = { uid:"", summary:"", description:"", location:"", status:"CONFIRMED", start:"", end:"" }
  for (let line of lines) {
    if (line.startsWith("UID:")) ev.uid = _kv(line).value
    else if (line.startsWith("SUMMARY:")) ev.summary = _kv(line).value
    else if (line.startsWith("DESCRIPTION:")) ev.description = _kv(line).value
    else if (line.startsWith("LOCATION:")) ev.location = _kv(line).value
    else if (line.startsWith("STATUS:")) ev.status = _kv(line).value
    else if (line.startsWith("DTSTART;VALUE=DATE:")) ev.start = _parseDt(_kv(line).value).iso
    else if (line.startsWith("DTEND;VALUE=DATE:")) ev.end = _parseDt(_kv(line).value).iso
    else if (line.startsWith("DTSTART:")) ev.start = _parseDt(_kv(line).value).iso
    else if (line.startsWith("DTEND:")) ev.end = _parseDt(_kv(line).value).iso
  }
  return ev
}
function _fmtDate(d){ const dt=new Date(d), p=n=>n<10?"0"+n:n; return dt.getFullYear()+""+p(dt.getMonth()+1)+p(dt.getDate()) }
function _fmtStamp(d){ const dt=new Date(d), p=n=>n<10?"0"+n:n
  return dt.getUTCFullYear()+""+p(dt.getUTCMonth()+1)+p(dt.getUTCDate())+"T"+p(dt.getUTCHours())+p(dt.getUTCMinutes())+p(dt.getUTCSeconds())+"Z"
}
function buildEvent(o){
  const L=[]
  L.push("BEGIN:VEVENT")
  L.push("UID:"+o.uid)
  L.push("DTSTAMP:"+o.dtstamp)
  if (o.allDay){
    L.push("DTSTART;VALUE=DATE:"+_fmtDate(o.start))
    L.push("DTEND;VALUE=DATE:"+_fmtDate(new Date(new Date(o.start).getTime()+86400000)))
  } else {
    L.push("DTSTART:"+_fmtStamp(o.start))
    const end = o.end ? o.end : new Date(new Date(o.start).getTime()+3600000).toISOString()
    L.push("DTEND:"+_fmtStamp(end))
  }
  L.push("SUMMARY:"+(o.summary||""))
  if (o.description) L.push("DESCRIPTION:"+o.description.replace(/\n/g,"\\n"))
  if (o.location) L.push("LOCATION:"+o.location)
  L.push("END:VEVENT")
  return L.join("\\r\\n") // CRLF + escaped for gdbus
}

// Export everything we need
var EDSParser = {
  parseOpenCalendar,
  extractCalendarSources,
  extractCalendarMeta,
  extractVEVENTs,
  toQueryUtc,
  nowUtcStamp,
  plusHour,
  windowStart,
  windowEnd,
  ICS: { parseEvent, buildEvent }
}