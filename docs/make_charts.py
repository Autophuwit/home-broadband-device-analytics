"""Render the portfolio charts for the household device analytics project.

All figures are RESCALED versions of the original results (counts scaled, shares slightly
perturbed, usage indexed). Relative patterns are preserved. Usage: python make_charts.py <output_dir>
"""
import sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.ticker import PercentFormatter, FuncFormatter

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

SURF, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
BLUE, ORANGE, AQUA, GRAY = "#2a78d6", "#eb6834", "#1baf7a", "#b9b8b0"

plt.rcParams.update({
    "font.family": ["Segoe UI", "DejaVu Sans"], "font.size": 11,
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "axes.edgecolor": AXIS, "axes.labelcolor": INK2, "text.color": INK,
    "xtick.color": MUTED, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False,
})

def title(ax, t, sub):
    ax.set_title(t, loc="left", fontsize=14, fontweight="bold", color=INK, pad=28)
    ax.text(0, 1.02, sub, transform=ax.transAxes, fontsize=10, color=INK2, va="bottom")

def save(fig, name):
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, name), dpi=200)
    plt.close(fig)

def grid_x(ax):
    ax.grid(axis="x", color=GRID, lw=0.8); ax.set_axisbelow(True)

K = FuncFormatter(lambda v, _: f"{v/1000:.0f}K")
M = FuncFormatter(lambda v, _: f"{v/1e6:.0f}M")

# ------------------------------------------------------------- 00a use-case cards
PAGE, CARD, LINE, VIOLET = "#f4f3ef", "#ffffff", "#e1e0d9", "#6250d6"
cards = [
    ("01", "Multi-device & high-usage homes", "“Stream smoothly at the same time”", BLUE,
     "730K", "48%", "124",
     [">= 8 active devices in the home", "No Mesh Wi-Fi installed", "Network quality & speed profile match"],
     ["Mesh Wi-Fi as the hero product", "Speed upgrade: plan or speed add-on"],
     "Mesh take-up  ·  speed-upgrade rate"),
    ("02", "CCTV expansion", "“Always online, so the home feels safe”", AQUA,
     "575K", "37%", "108",
     [">= 1 CCTV camera in the home, or", "Smart-home / IoT traffic >= 1% of usage", "(3x the network average)"],
     ["Operator CCTV", "Cloud recording storage", "Mesh Wi-Fi for camera coverage"],
     "CCTV attach rate  ·  cloud subscriptions"),
    ("03", "TV box cross-sell", "“A big-screen experience for the family”", VIOLET,
     "660K", "44%", "104",
     ["Smart TV or third-party TV box", "No operator TV box", "OTT streaming >= 100 MB / month"],
     ["Operator TV box", "OTT packs: sports, movies, kids", "Event campaigns for the big screen"],
     "TV box sales  ·  OTT pack attach"),
]

fig = plt.figure(figsize=(16, 8.6), facecolor=PAGE)
fig.text(0.03, 0.935, "Use cases built from household device behaviour", fontsize=24, fontweight="bold", color=INK)
fig.text(0.03, 0.895, "Each campaign has a target rule, a sized audience, an offer and a KPI to track", fontsize=12, color=INK2)
fig.text(0.97, 0.935, "Portfolio recreation  ·  rescaled figures", fontsize=10, color=MUTED, ha="right")

cw = (0.94 - 2 * 0.02) / 3
for i, (num, name, quote, c, big, share, usage, target, offer, kpi) in enumerate(cards):
    x0 = 0.03 + i * (cw + 0.02)
    ax = fig.add_axes([x0, 0.04, cw, 0.81]); ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")
    ax.add_patch(FancyBboxPatch((0, 0), 1, 1, boxstyle="round,pad=0,rounding_size=0.025", fc=CARD, ec=LINE, lw=1.2))
    ax.add_patch(plt.Rectangle((0.0, 0.985), 1, 0.015, fc=c, ec="none"))
    # header
    ax.scatter([0.085], [0.915], s=1500, color=c, zorder=3)
    ax.text(0.085, 0.913, num, ha="center", va="center", fontsize=12, fontweight="bold", color="#ffffff", zorder=4)
    ax.text(0.16, 0.925, name, fontsize=15.5, fontweight="bold", color=INK, va="center")
    ax.text(0.16, 0.878, quote, fontsize=11, style="italic", color=INK2, va="center")
    # hero metrics
    ax.add_patch(FancyBboxPatch((0.05, 0.655), 0.9, 0.17, boxstyle="round,pad=0,rounding_size=0.02", fc="#f6f8fc", ec="none"))
    ax.text(0.09, 0.765, "TARGET HOMES", fontsize=8.5, color=MUTED, fontweight="bold")
    ax.text(0.09, 0.695, big, fontsize=34, fontweight="bold", color=c, va="baseline")
    ax.text(0.64, 0.765, "OF ALL HOMES", fontsize=8.5, color=MUTED, fontweight="bold")
    ax.text(0.64, 0.695, share, fontsize=26, fontweight="bold", color=INK, va="baseline")
    ax.plot([0.58, 0.58], [0.68, 0.80], color=LINE, lw=1)
    # target / offer sections with fixed rows
    for sec, items, y0 in [("WHO WE TARGET", target, 0.585), ("WHAT WE OFFER", offer, 0.335)]:
        ax.text(0.06, y0, sec, fontsize=10, fontweight="bold", color=ORANGE)
        ax.plot([0.06, 0.94], [y0 - 0.02, y0 - 0.02], color=LINE, lw=1)
        for k, t in enumerate(items):
            yy = y0 - 0.068 - k * 0.058
            cont = t.startswith("(")
            if not cont:
                ax.scatter([0.08], [yy + 0.003], s=55, color=c, zorder=3)
            ax.text(0.11, yy, t, fontsize=11.5, color=INK2 if cont else INK, va="center",
                    fontweight="bold" if sec == "WHAT WE OFFER" else "normal")
    # KPI footer
    ax.add_patch(FancyBboxPatch((0.05, 0.035), 0.9, 0.075, boxstyle="round,pad=0,rounding_size=0.015", fc="#f4f3ef", ec="none"))
    ax.text(0.08, 0.072, "KPI", fontsize=9, fontweight="bold", color=MUTED, va="center")
    ax.text(0.17, 0.072, kpi, fontsize=10.5, color=INK, va="center")
fig.savefig(os.path.join(OUT, "00a_use_cases.png"), dpi=160, facecolor=PAGE); plt.close(fig)

# ------------------------------------------------------------- 00b brand landscape
fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.8), gridspec_kw={"width_ratios": [1.1, 1]})
brands = [("Samsung", .15), ("Apple", .12), ("OPPO", .10), ("vivo", .08), ("Operator brand", .07), ("Xiaomi", .06),
          ("realme", .03), ("HUAWEI", .02), ("Other brands", .05), ("No brand detected", .32)][::-1]
a1.barh([b[0] for b in brands], [b[1] for b in brands], height=0.62, zorder=2,
        color=[GRAY if b[0] == "No brand detected" else (ORANGE if b[0] == "Operator brand" else BLUE) for b in brands])
for i, b in enumerate(brands):
    a1.text(b[1] + 0.005, i, f"{b[1]:.0%}", va="center", fontsize=10, color=INK2)
a1.set_xlim(0, 0.38); a1.xaxis.set_major_formatter(PercentFormatter(1, decimals=0)); a1.tick_params(axis="y", length=0); grid_x(a1)
a1.set_title("Brand share of all active devices", loc="left", fontsize=12, fontweight="bold")
cat = ["TV box", "Mesh Wi-Fi", "CCTV camera"]; op = [.98, .70, .26]
a2.barh(cat[::-1], [1] * 3, color="#eeede8", height=0.55)
a2.barh(cat[::-1], op[::-1], color=ORANGE, height=0.55)
for i, v in enumerate(op[::-1]):
    a2.text(v - 0.02, i, f"{v:.0%}", va="center", ha="right", color="#ffffff", fontweight="bold")
a2.text(0.28, 0, "rest: Xiaomi 13%, TP-Link 8%,\nother IP-camera brands", fontsize=9.5, color=INK2, va="center")
a2.set_xlim(0, 1); a2.set_xticks([]); a2.tick_params(axis="y", length=0); a2.spines["bottom"].set_visible(False)
a2.set_title("Operator's share within the categories it sells", loc="left", fontsize=12, fontweight="bold")
fig.suptitle("Brand landscape: the operator dominates TV box and Mesh, but CCTV is contested", x=0.01, ha="left", fontsize=14, fontweight="bold")
fig.tight_layout(rect=(0, 0, 1, 0.93)); fig.savefig(os.path.join(OUT, "00b_brand_landscape.png"), dpi=200); plt.close(fig)

# ------------------------------------------------------------- 01 cleaning funnel
steps = [("Raw device-month records", 33.1e6, "13.2 / home"), ("De-duplicate renamed hostnames", 32.4e6, "12.9 / home"),
         ("Active days > 0 and connect time > 0", 30.0e6, "12.0 / home"), ("Active on >= 2 days", 22.7e6, "9.0 / home"),
         ("Connect time >= 30 s in the month", 20.6e6, "8.2 / home"),
         ("+ always-on home devices kept\n(TV, TV box, Mesh, CCTV, IoT)", 21.5e6, "8.6 / home")][::-1]
fig, ax = plt.subplots(figsize=(9, 4.8))
ax.barh([s[0] for s in steps], [s[1] for s in steps], color=[BLUE] + [GRAY] * 5, height=0.62, edgecolor=SURF, linewidth=2, zorder=2)
for i, (lab, v, p) in enumerate(steps):
    ax.text(v + 4e5, i, f"{v/1e6:.1f}M   ({p})", va="center", fontsize=10, color=INK2)
ax.set_xlim(0, 42e6); ax.xaxis.set_major_formatter(M); ax.tick_params(axis="y", length=0); grid_x(ax)
ax.set_xlabel("Devices (~2.5M home-broadband homes, one month)")
title(ax, "Cleaning removed 35% of raw device records as noise", "Router Wi-Fi logs -> one row per real device. Each step applied in order.")
save(fig, "01_cleaning_funnel.png")

# ------------------------------------------------------------- 02 devices per home
bins = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11+"]
share = [.07, .04, .04, .05, .06, .08, .08, .08, .07, .07, .06, .30]
fig, ax = plt.subplots(figsize=(9, 4.4))
ax.bar(bins, share, color=[ORANGE if b == "11+" else BLUE for b in bins], width=0.72, edgecolor=SURF, linewidth=2, zorder=2)
for i, s in enumerate(share):
    ax.text(i, s + 0.005, f"{s:.0%}", ha="center", fontsize=10, color=INK2)
ax.yaxis.set_major_formatter(PercentFormatter(1, decimals=0)); ax.set_ylim(0, 0.34)
ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
ax.set_xlabel("Active devices per home"); ax.set_ylabel("Share of homes")
title(ax, "About 9 devices per home, and 30% of homes run 11 or more", "Distribution of active Wi-Fi devices per home-broadband home")
save(fig, "02_devices_per_home.png")

# ------------------------------------------------------------- 03 device group mix
groups = [("Smartphone", .50), ("Unclassified", .23), ("CCTV camera", .07), ("Tablet", .05), ("PC / laptop", .05),
          ("TV box", .04), ("Smart TV", .02), ("IoT / smart home", .02), ("Mesh Wi-Fi", .01), ("Wearable", .01)][::-1]
home = ("Mesh Wi-Fi", "Smart TV", "TV box", "CCTV camera", "IoT / smart home")
fig, ax = plt.subplots(figsize=(9, 4.8))
ax.barh([g[0] for g in groups], [g[1] for g in groups], height=0.62, zorder=2, edgecolor=SURF, linewidth=2,
        color=[GRAY if g[0] == "Unclassified" else (ORANGE if g[0] in home else BLUE) for g in groups])
for i, g in enumerate(groups):
    ax.text(g[1] + 0.005, i, f"{g[1]:.0%}", va="center", fontsize=10, color=INK2)
ax.xaxis.set_major_formatter(PercentFormatter(1, decimals=0)); ax.set_xlim(0, 0.6); ax.tick_params(axis="y", length=0); grid_x(ax)
ax.set_xlabel("Share of active devices")
ax.scatter([], [], color=ORANGE, marker="s", s=60, label="Fixed home devices (upsell targets)")
ax.scatter([], [], color=BLUE, marker="s", s=60, label="Personal devices")
ax.legend(frameon=False, loc="lower right", fontsize=9.5)
title(ax, "77% of devices classified into 9 groups; home devices are the upsell gap",
      "Device mix across all active devices - Mesh Wi-Fi is on just 1% of devices")
save(fig, "03_device_group_mix.png")

# ------------------------------------------------------------- 04 CCTV scaling
cams = ["1", "2", "3", "4", "5", "6", "7", "8", "9+"]
op_pct = [.109, .197, .242, .287, .314, .411, .486, .606, .785]
mesh_pct = [.079, .096, .114, .131, .153, .167, .198, .270, .481]
fig, axes = plt.subplots(1, 2, figsize=(10, 4.4), sharey=True)
for ax, ys, c, t in [(axes[0], op_pct, BLUE, "% of CCTV homes using operator-brand cameras"),
                      (axes[1], mesh_pct, ORANGE, "% of CCTV homes that also have Mesh Wi-Fi")]:
    ax.plot(cams, ys, color=c, lw=2, marker="o", ms=7, markeredgecolor=SURF, markeredgewidth=1.5)
    for i in (0, len(cams) - 1):
        ax.text(i, ys[i] + 0.04, f"{ys[i]:.0%}", ha="center", fontsize=10, color=INK2)
    ax.set_ylim(0, 1); ax.yaxis.set_major_formatter(PercentFormatter(1, decimals=0))
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    ax.set_xlabel("Cameras in the home"); ax.set_title(t, loc="left", fontsize=11, color=INK, pad=8)
fig.suptitle("Small CCTV installs belong to competitor brands and lack Wi-Fi coverage", x=0.02, ha="left", fontsize=14, fontweight="bold")
fig.text(0.02, 0.885, "Homes with 1-2 cameras: mostly third-party brands, rarely Mesh -> upgrade target", fontsize=10, color=INK2)
fig.tight_layout(rect=(0, 0, 1, 0.88)); fig.savefig(os.path.join(OUT, "04_cctv_scaling.png"), dpi=200); plt.close(fig)

# ------------------------------------------------------------- 05 operator device footprint
combos = [("Operator TV box only", 646000), ("Operator CCTV only", 202000), ("TV box + CCTV", 144000),
          ("Mesh only", 43000), ("Mesh + TV box", 34000), ("Mesh + TV box + CCTV", 23000), ("Mesh + CCTV", 18000)][::-1]
fig, ax = plt.subplots(figsize=(9, 4.4))
ax.barh([c[0] for c in combos], [c[1] for c in combos], color=[BLUE if "+" not in c[0] else AQUA for c in combos],
        height=0.62, edgecolor=SURF, linewidth=2, zorder=2)
for i, c in enumerate(combos):
    ax.text(c[1] + 8000, i, f"{c[1]/1000:,.0f}K", va="center", fontsize=10, color=INK2)
ax.xaxis.set_major_formatter(K); ax.set_xlim(0, 750000); ax.tick_params(axis="y", length=0); grid_x(ax)
ax.scatter([], [], color=BLUE, marker="s", s=60, label="One operator product"); ax.scatter([], [], color=AQUA, marker="s", s=60, label="Two or more")
ax.legend(frameon=False, loc="lower right", fontsize=9.5); ax.set_xlabel("Homes")
title(ax, "~1.1M homes own an operator device, but 80% own only one", "Combinations of operator-branded devices detected in the home")
save(fig, "05_operator_device_footprint.png")
print("done")
