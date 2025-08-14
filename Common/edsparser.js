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
  // EXACTLY like calendar-cli.sh lines 128-142: only find sources with [Calendar] sections
  const text = raw.replace(/, /g, "\n")
  const uids = []
  
  // Parse the D-Bus response to find ALL sources with Calendar sections in their Data (lines 128-142)
  const regex = /UID.*<'([a-f0-9-]{32,40}|system-calendar)'>/g
  let match
  while ((match = regex.exec(text)) !== null) {
    const uid = match[1]
    
    // Check if this source has a [Calendar] section in its Data
    const idx = text.indexOf(uid)
    if (idx >= 0) {
      const chunk = text.slice(Math.max(0, idx - 2500), idx + 5000)
      if (chunk.indexOf("[Calendar]") >= 0) {
        uids.push(uid)
      }
    }
  }
  
  // Always include system-calendar since we know it works
  if (!uids.includes("system-calendar")) {
    uids.push("system-calendar")
  }
  
  return Array.from(new Set(uids))
}

function extractCalendarMeta(raw, uids) {
  const text = raw.replace(/, /g, "\n")
  return uids.map(uid => {
    let display = ""
    let backend = "unknown"
    
    // Get the source section for this specific UID - EXACTLY like calendar-cli.sh line 193
    const uidRegex = new RegExp(`UID.*<'${uid.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}'>`)
    const lines = text.split('\n')
    let startIndex = -1
    
    for (let i = 0; i < lines.length; i++) {
      if (uidRegex.test(lines[i])) {
        startIndex = i
        break
      }
    }
    
    if (startIndex >= 0) {
      // Get the next 50 lines after finding the UID (same as grep -A 50)
      const uidSection = lines.slice(startIndex, startIndex + 50).join('\n')
      
      // Extract the Data section content - EXACTLY like calendar-cli.sh lines 197-198
      // raw_data=$(echo "$uid_section" | grep "Data.*=" | sed "s/.*Data.*<'//; s/'>.*//; s/\\n/\n/g")
      const dataMatch = uidSection.match(/'Data':\s*<'([^']*(?:\\.[^']*)*)'>/)
      if (dataMatch) {
        let rawData = dataMatch[1]
        // Apply the same sed transformations: s/\\n/\n/g
        rawData = rawData.replace(/\\n/g, '\n')
        
        // Extract DisplayName= (the main English version) - EXACTLY like calendar-cli.sh line 202
        const displayNameMatch = rawData.match(/^DisplayName=(.+)$/m)
        if (displayNameMatch) {
          display = displayNameMatch[1]
        }
        
        // Extract BackendName from the Calendar section - EXACTLY like calendar-cli.sh lines 205-224
        const calendarSectionMatch = rawData.match(/\[Calendar\]\n([\s\S]*?)(?:\n\[|$)/)
        if (calendarSectionMatch) {
          const calendarSection = calendarSectionMatch[1]
          const backendMatch = calendarSection.match(/^BackendName=(.+)$/m)
          if (backendMatch) {
            const backendName = backendMatch[1]
            switch (backendName) {
              case "local":
                backend = "local"
                break
              case "contacts":
                backend = "contacts"
                break
              case "caldav":
                backend = "caldav"
                break
              default:
                backend = "unknown"
                break
            }
          }
        }
      }
    }
    
    // Fallback to a generic name if we couldn't extract it - same as calendar-cli.sh line 229
    if (!display || display.trim() === "") {
      display = "Calendar " + uid
    }
    
    return { uid: uid, name: display, backend: backend, enabled: true }
  })
}

function extractVEVENTs(raw) {
  const out = []
  const re = /'([^']*BEGIN:VEVENT[^']*END:VEVENT[^']*)'/g
  let m
  while ((m = re.exec(raw)) !== null) {
    // Properly handle escaped sequences: \r\n, \n, and \r
    const cleaned = m[1].replace(/\\r\\n/g, "\n").replace(/\\n/g, "\n").replace(/\\r/g, "\n")
    out.push(cleaned)
  }
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
  // Handle both literal \r\n sequences and actual CRLF
  const normalizedIcs = ics.replace(/\\r\\n/g, '\n').replace(/\r\n/g, '\n').replace(/\r/g, '\n')
  const lines = normalizedIcs.split('\n')
  const ev = { uid:"", summary:"", description:"", location:"", status:"CONFIRMED", start:"", end:"" }
  
  let inValarm = false
  
  for (let line of lines) {
    line = line.trim()
    
    // Skip VALARM blocks which contain "Alarm notification" text
    if (line === "BEGIN:VALARM") {
      inValarm = true
      continue
    } else if (line === "END:VALARM") {
      inValarm = false
      continue
    }
    
    // Skip lines inside VALARM blocks
    if (inValarm) continue
    
    // Parse main event fields with proper escape sequence handling
    if (line.startsWith("UID:")) ev.uid = _kv(line).value.trim()
    else if (line.startsWith("SUMMARY:")) ev.summary = _kv(line).value.trim()
    else if (line.startsWith("DESCRIPTION:")) ev.description = _kv(line).value.trim()
    else if (line.startsWith("LOCATION:")) {
      // Clean escape sequences from location field
      const rawLocation = _kv(line).value.trim()
      ev.location = rawLocation
        .replace(/\\r\\n/g, ', ')  // Convert \r\n to comma-space
        .replace(/\\n/g, ', ')    // Convert \n to comma-space  
        .replace(/\\r/g, ', ')    // Convert \r to comma-space
        .replace(/\\\\,/g, ',')   // Convert double-backslash-comma \\, to regular commas
        .replace(/\\,/g, ',')     // Convert escaped commas \, to regular commas
        .replace(/\\;/g, ';')     // Convert escaped semicolons \; to regular semicolons
        .replace(/\\:/g, ':')     // Convert escaped colons \: to regular colons
        .replace(/\\\\/g, '\\')   // Convert \\ to \ (must be after other escape sequences)
        .replace(/,\s*,+/g, ', ') // Clean up multiple consecutive commas
        .replace(/,\s+,/g, ', ')  // Clean up comma-space-comma patterns
        .replace(/\s+/g, ' ')     // Normalize multiple spaces to single space
        .replace(/^,\s*/, '')     // Remove leading comma
        .replace(/,\s*$/, '')     // Remove trailing comma
        .trim()                   // Final trim
    }
    else if (line.startsWith("STATUS:")) ev.status = _kv(line).value.trim()
    else if (line.startsWith("DTSTART;VALUE=DATE:")) ev.start = _parseDt(_kv(line).value.trim()).iso
    else if (line.startsWith("DTEND;VALUE=DATE:")) ev.end = _parseDt(_kv(line).value.trim()).iso
    else if (line.startsWith("DTSTART:")) ev.start = _parseDt(_kv(line).value.trim()).iso
    else if (line.startsWith("DTEND:")) ev.end = _parseDt(_kv(line).value.trim()).iso
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