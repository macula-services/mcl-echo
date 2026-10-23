"""Generate mcl-echo's two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks and the capability in
mcl_echo_service.erl, the handler in mcl_echo_mesh_rpc.erl, the empty
supervisor, the dependencies in rebar.config, the org and realm in
config/sys.config.src, and the station list in mcl_echo_stations.erl. When one
of those changes, the diagram changes in the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-echo system context", 1000, 680)
    d.box("b-per", 40, 30, 280, 120, "Caller", "[Person]",
          ["An SDK quickstart, an agent, or a", "fan-out test. Picks a station and",
           "calls mcl-echo/echo"], person=True)
    d.box("b-per", 690, 30, 270, 120, "Service operator", "[Person]",
          ["Deploys the release and supplies", "the realm, its key and the station",
           "pins"], person=True)
    d.box("b-sys", 365, 200, 270, 152, "mcl-echo", "[mcl_om mesh service, own box]",
          ["mcl-echo/echo is its own procedure.", "mcl_om adds info and get_limits, both",
           "open. capabilities/0 is the list.", "/health is a Unix socket; no store,",
           "no clock."])
    d.box("b-mac", 40, 430, 280, 120, "macula-realm", "[Macula infrastructure]",
          ["Endorses the node's identity key", "and issues the D25 delegation for",
           "org mcl-echo, whose procedure it names"])
    d.box("b-mac", 365, 430, 270, 136, "Macula stations, mesh DHT", "[Macula infrastructure]",
          ["The caller's route in, six public", "stations and the DHT route an org",
           "procedure. mcl-echo dials its own", "pinned seeds, IPv6 only, pin enforced"])
    d.box("b-ext", 680, 430, 280, 120, "mcl-sec-guard", "[External system]",
          ["Reads the denials_observed facts", "the platform publishes, one per",
           "window with a denial"])
    d.edge("M180 150V180H400V200")
    d.text("t-rel", 200, 160, "calls mcl-echo/echo")
    d.text("t-rel", 200, 176, "with any payload")
    d.edge("M825 150V180H620V200")
    d.text("t-rel", 640, 160, "deploys; supplies the realm,")
    d.text("t-rel", 640, 176, "its key and the station pins")
    d.edge("M420 352V390H180V430"); d.text("t-rel", 300, 382, "boot claim, D25 delegation")
    d.edge("M520 352V430"); d.text("t-rel", 512, 404, "dials its pinned seeds; advertises the echo", anchor="end")
    d.edge("M600 352V390H820V430"); d.text("t-rel", 620, 384, "denials_observed, when a limit denies")
    d.text("t-desc", 40, 588, "The echo is a canary, not a service with state: its answers are the payload back, and its job is to be the first call every")
    d.text("t-desc", 40, 606, "SDK quickstart makes. The limits and the denials are the platform's (mcl_om's inbound guard), so nothing here counts, throttles")
    d.text("t-desc", 40, 624, "or stores; the realm's delegation is what makes its own procedure reachable at all.")
    d.legend(652, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-echo components", 1000, 780)
    d.bound(16, 40, 968, 510, "mcl-echo [Container]")
    d.box("b-mac", 32, 70, 456, 130, "mcl_om", "[library, ~> 1.4]",
          ["boot/1: loads the node identity key, joins the realm, dials the",
           "pinned stations, registers the echo and re-advertises it on a",
           "tick, serves /health on the socket"], code=True)
    d.box("b-mac", 512, 70, 456, 130, "macula SDK", "[library, ~> 16.0, wire 1.0]",
          ["QUIC transport, signed calls, sealed payloads (kem_advertise),",
           "and the realm key every org-namespaced advertisement is",
           "verified against"], code=True)
    d.box("b-sys", 32, 230, 456, 140, "mcl_echo_service", "[mcl_om_service behaviour]",
          ["The six mcl_om_service callbacks, resolved by",
           "name; mcl-om adds the open info and get_limits.",
           "capabilities/0 asserts the realm and org, then",
           "declares the echo and its limits"], code=True)
    d.box("b-cmp", 512, 230, 456, 130, "mcl_echo_sup", "[supervisor, one_for_one]",
          ["No children: mcl-om owns the registration",
           "of what this service advertises; the inbound",
           "guard is the pipeline's; the echo is stateless."], code=True)
    d.box("b-cmp", 32, 390, 456, 140, "inbound guard, the platform's", "[mcl_om pipeline, before the handler]",
          ["Payload size first (4096 bytes, erlang:external_size), then a",
           "fixed 10 s window of 20 calls per caller and 300 globally. Over",
           "either: payload_too_large or rate_limited. Counts denials and",
           "publishes denials_observed once per window with activity"], code=True)
    d.box("b-sys", 512, 390, 456, 140, "mcl_echo_mesh_rpc", "[macula_response RPC provider]",
          ["handle_request/2 replies with the payload unchanged, minus the",
           "platform-injected caller, so a caller is never shown a field they",
           "did not send. Stateless: no store, no clock, no side effect of",
           "its own"], code=True)
    d.box("b-ext", 32, 570, 936, 104, "host environment", "[environment, from the host; the identity key is the only volume]",
          ["MCL_REALM, MCL_REALM_KEY, MACULA_STATION_SEEDS, MACULA_STATION_NODE_IDS, MCL_SERVICE_NAME, MCL_BOX. The identity key is",
           "mounted at /etc/mcl/secrets/identity.key. The org, mcl-echo, is a literal in sys.config, not a host variable"])
    d.edge("M488 135H512"); d.text("t-rel", 500, 62, "calls", anchor="middle")
    d.edge("M260 200V230"); d.text("t-rel", 268, 224, "boots through mcl_om:boot/1")
    d.edge("M488 295H512"); d.text("t-rel", 500, 288, "starts", anchor="middle", rotate=-90)
    d.edge("M260 360V390"); d.text("t-rel", 268, 384, "declares the limits")
    d.edge("M488 460H512"); d.text("t-rel", 500, 460, "then the handler", anchor="middle", rotate=-90)
    d.text("t-desc", 40, 700, "config/sys.config.src fixes the org, mcl-echo, whose name prefixes procedure names; the realm is the io.macula tag. Both are asserted at")
    d.text("t-desc", 40, 716, "boot, because an org drift renames procedure names to ones no caller uses and a realm mismatch is silent on the wire.")
    d.legend(752, boundary=False)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
