#!/usr/bin/env python3
"""
amt.py — out-of-band control of Intel AMT / vPro machines over WS-Management.

Written to bring up the TCx Wave dashboard kiosks (Toshiba 6140-E45, AMT 11.8)
headlessly: query/set power, and turn on KVM (VNC on :5900) so a fresh install
that lands in an initrd emergency shell can be recovered without a keyboard on
the unit. Works against any AMT machine, not just the kiosks.

Why hand-rolled SOAP instead of wsmancli/amttool:
  - amttool speaks the legacy pre-11 SOAP interface AMT 11.x dropped (its
    `info` 404s); it can read the version but not much else.
  - wsmancli's partial PUTs are rejected by AMT's strict schema validator.
  AMT wants a byte-exact WS-Man envelope. The gotchas we hit and encode here:
  - A PUT of IPS_KVMRedirectionSettingData must contain the writable fields
    ONLY (drop read-only EnabledByMEBx / keys) OR echo the full GET body; and
    property ORDER must match the schema. We echo the GET body and mutate in
    place, which satisfies both.
  - Is5900PortEnabled=true is refused ("operation parameter not valid") unless
    a valid RFBPassword is set in the same or a prior PUT.
  - The RFB password must satisfy AMT's strong-password policy: 8..32 chars
    with upper+lower+digit+special. VNC auth only uses the first 8 chars, so we
    keep it exactly 8 (e.g. "Amt2026!").
  - Enabling the port is not enough: the KVM SAP (CIM_KVMRedirectionSAP) must
    be moved to RequestedState=2 (Enabled) before :5900 actually listens.

SOL (Serial-Over-LAN, :16994/:16995) is simpler than KVM: AMT_RedirectionService
has one ListenerEnabled flag (no separate SAP RequestStateChange dance) — same
"echo the GET body, mutate in place, PUT" pattern, just one field. This script
only flips that flag; the actual serial client is `amtterm` (nixpkgs `amtterm`)
or `gamt`, since driving AMT's SOL wire protocol byte-for-byte isn't worth
reimplementing here.

Usage:
  export AMT_HOST=10.1.1.165
  export AMT_PASSWORD='...'         # AMT admin password (MEBx/provisioned)
  # optional: AMT_USER (default admin), AMT_PORT (default 16992)

  ./amt.py info                     # power state + AMT version + redirection state
  ./amt.py power                    # just the power state
  ./amt.py on | off | reset | cycle # power control
  ./amt.py enable-kvm [RFBPW]       # set RFB pw (default Amt2026!), open :5900
  ./amt.py disable-kvm              # stop KVM SAP + close :5900 (hygiene)
  ./amt.py screenshot [out.png]     # needs vncdotool; grabs the console
  ./amt.py enable-sol               # turn on the SOL/IDER listener (:16994/16995)
  ./amt.py disable-sol              # turn it back off (hygiene)

Recovering a kiosk stuck in the initrd emergency shell (ZFS import failed on
first boot — see modules/common.nix boot.zfs.forceImportRoot):
  ./amt.py enable-kvm
  ./amt.py reset                    # then watch POST/boot menu over VNC :5900,
  # at the systemd-boot menu press 'e' and append  zfs_force=1  for a one-time
  # forced import, or reinstall with the fixed config. Once the pool imports
  # under the host's own hostId, later boots are fine.
  ./amt.py disable-kvm              # when done

Watching a boot from POST through userspace over serial (no monitor needed):
  ./amt.py enable-sol
  ./amt.py reset
  AMT_PASSWORD=... amtterm -u admin $AMT_HOST   # ^] to escape
  ./amt.py disable-sol              # when done
"""
import os, sys, uuid, re, requests
from requests.auth import HTTPDigestAuth

HOST = os.environ.get("AMT_HOST")
USER = os.environ.get("AMT_USER", "admin")
PORT = int(os.environ.get("AMT_PORT", "16992"))
PW   = os.environ.get("AMT_PASSWORD")
if not HOST or not PW:
    sys.exit("set AMT_HOST and AMT_PASSWORD in the environment")
URL  = f"http://{HOST}:{PORT}/wsman"
AUTH = HTTPDigestAuth(USER, PW)

XFER = "http://schemas.xmlsoap.org/ws/2004/09/transfer"
ENUM = "http://schemas.xmlsoap.org/ws/2004/09/enumeration"
KVMSET = "http://intel.com/wbem/wscim/1/ips-schema/1/IPS_KVMRedirectionSettingData"
KVMSAP = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_KVMRedirectionSAP"
REDIR  = "http://intel.com/wbem/wscim/1/amt-schema/1/AMT_RedirectionService"
PMSVC  = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_PowerManagementService"
PMASSOC= "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_AssociatedPowerManagementService"
CS_KEY = {  # selectors for the managed computer system power service
    "Name": "Intel(r) AMT Power Management Service",
    "SystemCreationClassName": "CIM_ComputerSystem",
    "SystemName": "Intel(r) AMT",
    "CreationClassName": "CIM_PowerManagementService",
}

def envelope(action, resource, body="", selectors=None):
    sel = ""
    if selectors:
        sel = "<w:SelectorSet>" + "".join(
            f'<w:Selector Name="{k}">{v}</w:Selector>' for k, v in selectors.items()
        ) + "</w:SelectorSet>"
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd">
<s:Header><a:To>{URL}</a:To><w:ResourceURI>{resource}</w:ResourceURI>
<a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
<a:Action s:mustUnderstand="true">{action}</a:Action><a:MessageID>uuid:{uuid.uuid4()}</a:MessageID>
<w:OperationTimeout>PT60S</w:OperationTimeout>{sel}</s:Header><s:Body>{body}</s:Body></s:Envelope>'''

def post(xml):
    r = requests.post(URL, data=xml.encode(), auth=AUTH,
                      headers={"Content-Type": "application/soap+xml;charset=UTF-8"}, timeout=30)
    return r.status_code, r.text

def fault(text):
    m = re.search(r"<[a-z]:Text[^>]*>([^<]+)</", text)
    return m.group(1) if m else None

def get(resource, selectors=None):
    return post(envelope(f"{XFER}/Get", resource, "", selectors))

def enumerate_pull(resource):
    _, t = post(envelope(f"{ENUM}/Enumerate", resource,
                         '<e:Enumerate xmlns:e="%s"/>' % ENUM))
    ctx = re.search(r"<[a-z]:EnumerationContext>([^<]+)</", t)
    if not ctx:
        return t
    pb = ('<e:Pull xmlns:e="%s"><e:EnumerationContext>%s</e:EnumerationContext>'
          '<e:MaxElements>20</e:MaxElements></e:Pull>' % (ENUM, ctx.group(1)))
    _, t = post(envelope(f"{ENUM}/Pull", resource, pb))
    return t

POWER_NAMES = {"2":"On (S0)","3":"Sleep light (S1)","4":"Sleep deep (S3)",
               "6":"Off (S5)","7":"Hibernate (S4)","8":"Off (soft)","13":"Off (hard)"}

def power_state():
    t = enumerate_pull(PMASSOC)
    m = re.search(r"PowerState>([0-9]+)<", t)
    return m.group(1) if m else "?"

def request_power(state):
    body = (f'<p:RequestPowerStateChange_INPUT xmlns:p="{PMSVC}">'
            f'<p:PowerState>{state}</p:PowerState>'
            f'<p:ManagedElement xmlns:x="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
            f'<x:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</x:Address>'
            f'<x:ReferenceParameters xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd">'
            f'<w:ResourceURI>http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ComputerSystem</w:ResourceURI>'
            f'<w:SelectorSet><w:Selector Name="CreationClassName">CIM_ComputerSystem</w:Selector>'
            f'<w:Selector Name="Name">ManagedSystem</w:Selector></w:SelectorSet>'
            f'</x:ReferenceParameters></p:ManagedElement></p:RequestPowerStateChange_INPUT>')
    c, t = post(envelope(f"{PMSVC}/RequestPowerStateChange", PMSVC, body, CS_KEY))
    rv = re.search(r"ReturnValue>([0-9]+)<", t)
    return rv.group(1) if rv else fault(t) or f"http {c}"

# AMT power-state change codes for RequestPowerStateChange
POWER_ACTIONS = {"on":2, "cycle":5, "off":8, "reset":10}

def enable_kvm(rfbpw="Amt2026!"):
    if not (8 <= len(rfbpw) <= 32):
        sys.exit("RFB password must be 8..32 chars (VNC uses first 8)")
    # 1) echo the GET body, mutate password + port + timeout in place
    _, g = get(KVMSET)
    m = re.search(r"(<g:IPS_KVMRedirectionSettingData>.*?</g:IPS_KVMRedirectionSettingData>)", g, re.S)
    if not m:
        sys.exit("could not read KVM settings")
    body = m.group(1).replace("<g:IPS_KVMRedirectionSettingData>",
                              f'<g:IPS_KVMRedirectionSettingData xmlns:g="{KVMSET}">')
    body = re.sub(r"<g:RFBPassword>[^<]*</g:RFBPassword>|<g:RFBPassword/>",
                  f"<g:RFBPassword>{rfbpw}</g:RFBPassword>", body)
    body = body.replace("<g:Is5900PortEnabled>false</g:Is5900PortEnabled>",
                        "<g:Is5900PortEnabled>true</g:Is5900PortEnabled>")
    body = re.sub(r"<g:SessionTimeout>[0-9]+</g:SessionTimeout>",
                  "<g:SessionTimeout>0</g:SessionTimeout>", body)
    c, t = post(envelope(f"{XFER}/Put", KVMSET, body))
    if c != 200:
        sys.exit(f"KVM settings PUT failed: {fault(t)}")
    # 2) move the KVM SAP to Enabled(2) so :5900 actually listens
    _, s = get(KVMSAP)
    sels = {}
    for k in ("Name", "CreationClassName", "SystemName", "SystemCreationClassName"):
        mm = re.search(rf"<[a-z]:{k}>([^<]*)</", s)
        if mm: sels[k] = mm.group(1)
    body = f'<r:RequestStateChange_INPUT xmlns:r="{KVMSAP}"><r:RequestedState>2</r:RequestedState></r:RequestStateChange_INPUT>'
    c, t = post(envelope(f"{KVMSAP}/RequestStateChange", KVMSAP, body, sels))
    rv = re.search(r"ReturnValue>([0-9]+)<", t)
    print(f"KVM enabled on {HOST}:5900  (rfb pw '{rfbpw}', SAP rv={rv.group(1) if rv else fault(t)})")

def disable_kvm():
    _, s = get(KVMSAP)
    sels = {}
    for k in ("Name", "CreationClassName", "SystemName", "SystemCreationClassName"):
        mm = re.search(rf"<[a-z]:{k}>([^<]*)</", s)
        if mm: sels[k] = mm.group(1)
    body = f'<r:RequestStateChange_INPUT xmlns:r="{KVMSAP}"><r:RequestedState>3</r:RequestedState></r:RequestStateChange_INPUT>'
    post(envelope(f"{KVMSAP}/RequestStateChange", KVMSAP, body, sels))
    # close the port
    _, g = get(KVMSET)
    m = re.search(r"(<g:IPS_KVMRedirectionSettingData>.*?</g:IPS_KVMRedirectionSettingData>)", g, re.S)
    body = m.group(1).replace("<g:IPS_KVMRedirectionSettingData>",
                              f'<g:IPS_KVMRedirectionSettingData xmlns:g="{KVMSET}">')
    body = body.replace("<g:Is5900PortEnabled>true</g:Is5900PortEnabled>",
                        "<g:Is5900PortEnabled>false</g:Is5900PortEnabled>")
    post(envelope(f"{XFER}/Put", KVMSET, body))
    print(f"KVM disabled on {HOST}")

def _set_redirection_listener(enabled):
    _, g = get(REDIR)
    m = re.search(r"(<g:AMT_RedirectionService>.*?</g:AMT_RedirectionService>)", g, re.S)
    if not m:
        sys.exit("could not read AMT_RedirectionService settings")
    body = m.group(1).replace("<g:AMT_RedirectionService>",
                              f'<g:AMT_RedirectionService xmlns:g="{REDIR}">')
    body = re.sub(r"<g:ListenerEnabled>[a-z]+</g:ListenerEnabled>",
                  f"<g:ListenerEnabled>{'true' if enabled else 'false'}</g:ListenerEnabled>", body)
    c, t = post(envelope(f"{XFER}/Put", REDIR, body))
    if c != 200:
        sys.exit(f"AMT_RedirectionService PUT failed: {fault(t)}")
    return c

def enable_sol():
    _set_redirection_listener(True)
    print(f"SOL/IDER listener enabled on {HOST}:16994/16995")

def disable_sol():
    _set_redirection_listener(False)
    print(f"SOL/IDER listener disabled on {HOST}")

def info():
    _, ident = post(envelope("http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd/Get", ""))
    ps = power_state()
    print(f"host        : {HOST}")
    print(f"power state : {ps} {POWER_NAMES.get(ps,'?')}")
    _, r = get(REDIR)
    le = re.search(r"ListenerEnabled>([a-z]+)<", r)
    print(f"redir listen: {le.group(1) if le else '?'} (SOL/IDER on :16994/16995)")
    _, k = get(KVMSET)
    p5 = re.search(r"Is5900PortEnabled>([a-z]+)<", k)
    print(f"kvm :5900   : {p5.group(1) if p5 else '?'}")

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "info": info()
    elif cmd == "power": print(power_state(), POWER_NAMES.get(power_state(), ""))
    elif cmd in POWER_ACTIONS:
        print(f"{cmd}: rv={request_power(POWER_ACTIONS[cmd])} (0=ok)")
    elif cmd == "enable-kvm": enable_kvm(*(sys.argv[2:3] or []))
    elif cmd == "disable-kvm": disable_kvm()
    elif cmd == "enable-sol": enable_sol()
    elif cmd == "disable-sol": disable_sol()
    elif cmd == "screenshot":
        out = sys.argv[2] if len(sys.argv) > 2 else "amt-screen.png"
        os.execvp("vncdo", ["vncdo", "-s", f"{HOST}::5900", "-p",
                            os.environ.get("AMT_RFBPW", "Amt2026!"), "capture", out])
    else:
        print(__doc__); sys.exit(1)

if __name__ == "__main__":
    main()
