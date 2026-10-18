#!/usr/bin/env python3
"""mapas.py — dibuja los mapas del informe desde resultados/mapas.gpkg.

Requiere:  pip install geopandas matplotlib
Salidas:   resultados/mapa1_grilla.png            (Q6, mapa principal)
           resultados/mapa2_densidad_paraderos.png (Q1)
Las fuentes y fechas del pie de cada mapa se leen de la capa 'fuentes' del GeoPackage
(que a su vez sale de etl_log), no están escritas a mano.
"""
from pathlib import Path

import geopandas as gpd
import matplotlib

matplotlib.use("Agg")
import matplotlib.patheffects as pe
import matplotlib.pyplot as plt
from matplotlib.cm import ScalarMappable
from matplotlib.colors import PowerNorm, Normalize
from matplotlib.patches import Patch
from matplotlib.ticker import FuncFormatter, MaxNLocator

GPKG = Path(__file__).resolve().parent.parent / "resultados" / "mapas.gpkg"
OUT = GPKG.parent
GRIS = "#e9e9e9"
HALO = [pe.withStroke(linewidth=2.2, foreground="white")]


# ---------------------------------------------------------------- utilidades
def pie_fuentes():
    """Texto de fuentes y fechas, tomado de la capa 'fuentes'."""
    f = gpd.read_file(GPKG, layer="fuentes").set_index("paso")["detalle"].to_dict()
    osm = f.get("fuente_osm_fecha", "s/f")[:10]
    gtfs = f.get("fuente_gtfs", "GTFS").replace(".zip", "")
    feed = f.get("fuente_gtfs_feed", "")
    return (f"Fuentes: © OpenStreetMap contributors (ODbL), extracto del {osm} · DPA 2023 · SRID 5361 (SIRGAS-Chile / UTM 19S)\n"
            f"GTFS DTPM: {gtfs} ({feed})")


def formato_km(ax):
    ax.xaxis.set_major_locator(MaxNLocator(4))
    ax.yaxis.set_major_locator(MaxNLocator(5))
    km = FuncFormatter(lambda v, _: f"{v / 1000:.0f}")
    ax.xaxis.set_major_formatter(km)
    ax.yaxis.set_major_formatter(km)
    ax.tick_params(labelsize=7)
    ax.set_xlabel("Este (km)", fontsize=7)
    ax.set_ylabel("Norte (km)", fontsize=7)


def escala_grafica(ax, km=5):
    x0, x1, y0, y1 = *ax.get_xlim(), *ax.get_ylim()
    x, y = x0 + 0.04 * (x1 - x0), y0 + 0.05 * (y1 - y0)
    ax.plot([x, x + km * 1000], [y, y], color="k", lw=2.5, solid_capstyle="butt", zorder=9)
    ax.text(x + km * 500, y + 0.012 * (y1 - y0), f"{km} km", ha="center", fontsize=7, zorder=9, path_effects=HALO)


def norte(ax):
    x0, x1, y0, y1 = *ax.get_xlim(), *ax.get_ylim()
    x, y = x1 - 0.05 * (x1 - x0), y1 - 0.14 * (y1 - y0)
    ax.annotate("", xy=(x, y + 0.09 * (y1 - y0)), xytext=(x, y),
                arrowprops=dict(arrowstyle="-|>", color="k", lw=1.5), zorder=9)
    ax.text(x, y + 0.10 * (y1 - y0), "N", ha="center", fontsize=9, weight="bold", zorder=9, path_effects=HALO)


# --------------------------------------------------------- Mapa 1: la grilla
def mapa_grilla(pie):
    g = gpd.read_file(GPKG, layer="grilla")
    com = gpd.read_file(GPKG, layer="comunas_densidad")
    top = g[g["rank_top"].notna()].sort_values("rank_top")
    xmin, ymin, xmax, ymax = g.total_bounds

    fig, axes = plt.subplots(1, 2, figsize=(13, 6.6))
    paneles = [
        ("n_edificios", "YlOrRd", PowerNorm(0.5, vmin=1, vmax=g["n_edificios"].max()),
         "Edificios por celda (OSM)", "Ciudad construida: edificios por hexágono"),
        ("n_recorridos", "Blues", Normalize(vmin=1, vmax=g["n_recorridos"].max()),
         "Recorridos distintos que cruzan la celda (GTFS)", "Oferta de transporte: recorridos distintos por hexágono"),
    ]
    for ax, (col, cmap, norm, etiqueta, sub) in zip(axes, paneles):
        g.plot(ax=ax, color=GRIS, edgecolor="none")                                  # celdas con valor 0
        g[(g[col] > 0) & g["interior"]].plot(ax=ax, column=col, cmap=cmap, norm=norm, edgecolor="none")
        g[(g[col] > 0) & ~g["interior"]].plot(ax=ax, column=col, cmap=cmap, norm=norm, edgecolor="none", alpha=0.45)
        com.boundary.plot(ax=ax, color="#555555", linewidth=0.5, zorder=3)
        top.boundary.plot(ax=ax, color="black", linewidth=1.6, zorder=5)
        for _, r in top.iterrows():
            c = r.geometry.centroid
            ax.text(c.x, c.y, str(int(r.rank_top)), ha="center", va="center", fontsize=7,
                    weight="bold", zorder=6, path_effects=HALO)
        if col == "n_edificios":                                                      # nombres solo en un panel
            for _, r in com[com["area_zona_km2"] >= 14].iterrows():
                p = r.geometry.representative_point()
                ax.text(p.x, p.y, r["comuna"], ha="center", fontsize=6, color="#333333",
                        style="italic", zorder=4, path_effects=HALO)
        ax.set_xlim(xmin, xmax)
        ax.set_ylim(ymin, ymax)
        ax.set_aspect("equal")
        formato_km(ax)
        if col == "n_recorridos":                       # eje Norte compartido: solo en el panel izquierdo
            ax.set_ylabel("")
            ax.tick_params(labelleft=False)
        ax.set_title(sub, fontsize=9)
        cb = fig.colorbar(ScalarMappable(norm=norm, cmap=cmap), ax=ax, fraction=0.04, pad=0.02)
        cb.set_label(etiqueta, fontsize=8)
        cb.ax.tick_params(labelsize=7)
        escala_grafica(ax)
        ax.legend(handles=[Patch(facecolor=GRIS, label="0 (sin edificios)" if col == "n_edificios" else "0 (sin recorridos)"),
                           Patch(facecolor="none", edgecolor="black", linewidth=1.6, label="Top 10: edificios / (recorridos + 1)"),
                           Patch(facecolor="#bbbbbb", alpha=0.45, label="Celda de borde (subcuenta edificios)")],
                  loc="lower right", fontsize=6.5, framealpha=0.9)
    norte(axes[1])
    n_sin = int(((g.n_edificios > 0) & (g.n_recorridos == 0) & g.interior).sum())
    fig.suptitle("Santiago centro: ciudad construida frente a oferta de transporte público\n"
                 "Hexágonos de 500 m de lado (≈ 0,65 km²). Contorno negro y número: las 10 celdas interiores con mayor razón edificios / (recorridos + 1)",
                 fontsize=11, weight="bold")
    fig.text(0.5, 0.075, f"{n_sin} celdas interiores con edificios no son cruzadas por ningún recorrido GTFS. "
             "Recorridos = los declarados en el GTFS (buses, Metro y tren); lo no dibujado en OSM o no declarado por el operador no aparece.",
             ha="center", fontsize=7.5)
    fig.text(0.5, 0.012, pie, ha="center", fontsize=6.5, color="#444444")
    fig.subplots_adjust(left=0.06, right=0.97, top=0.84, bottom=0.14, wspace=0.14)
    fig.savefig(OUT / "mapa1_grilla.png", dpi=200)
    plt.close(fig)


# ------------------------------------------------ Mapa 2: densidad por comuna
def mapa_densidad(pie):
    com = gpd.read_file(GPKG, layer="comunas_densidad")
    par = gpd.read_file(GPKG, layer="paraderos")
    xmin, ymin, xmax, ymax = com.total_bounds
    norm = PowerNorm(0.7, vmin=0, vmax=com.loc[com["area_zona_km2"] >= 2, "paraderos_km2"].max())
    cmap = "YlGnBu"

    plt.rcParams["hatch.linewidth"] = 0.6
    fig, ax = plt.subplots(figsize=(9, 8.8))
    parcial = com["pct_comuna_en_zona"] < 90
    com.plot(ax=ax, column="paraderos_km2", cmap=cmap, norm=norm, edgecolor="none")
    com[parcial].plot(ax=ax, facecolor="none", edgecolor="white", hatch="///", linewidth=0)   # hachurado liviano
    com.boundary.plot(ax=ax, color="#333333", linewidth=0.7)
    par.plot(ax=ax, color="#222222", markersize=0.8, alpha=0.45, zorder=4)
    for _, r in com[com["area_zona_km2"] >= 4].iterrows():  # astillas (< 4 km²) sin rótulo
        p = r.geometry.representative_point()
        ax.text(p.x, p.y, f"{r['comuna']}\n{r['paraderos_km2']:.0f}", ha="center", va="center",
                fontsize=6, zorder=6, path_effects=HALO)
    ax.set_xlim(xmin, xmax)
    ax.set_ylim(ymin, ymax)
    ax.set_aspect("equal")
    formato_km(ax)
    cb = fig.colorbar(ScalarMappable(norm=norm, cmap=cmap), ax=ax, fraction=0.04, pad=0.02, extend="max")
    cb.set_label("Paraderos GTFS por km² (sobre el área de la comuna dentro de la zona)", fontsize=8)
    cb.ax.tick_params(labelsize=7)
    escala_grafica(ax)
    norte(ax)
    ax.legend(handles=[Patch(facecolor="#7fcdbb", edgecolor="white", hatch="///", label="Comuna parcialmente dentro de la zona (< 90 %)"),
                       plt.Line2D([], [], marker="o", color="none", markerfacecolor="#222222", markersize=3, label="Paradero GTFS")],
              loc="upper center", bbox_to_anchor=(0.5, -0.09), ncol=2, fontsize=7.5, frameon=False)
    ax.set_title("Densidad de paraderos GTFS por comuna — Santiago centro\n"
                 "Número bajo el nombre: paraderos/km². Solo paraderos (sin estaciones ni accesos de metro)",
                 fontsize=10, weight="bold")
    fig.text(0.5, 0.012, "Las comunas hachuradas quedan cortadas por la zona de estudio: su densidad es la del trozo visible.\n" + pie,
             ha="center", fontsize=6.3, color="#444444")
    fig.subplots_adjust(left=0.07, right=0.97, top=0.91, bottom=0.17)
    fig.savefig(OUT / "mapa2_densidad_paraderos.png", dpi=200)
    plt.close(fig)


if __name__ == "__main__":
    if not GPKG.exists():
        raise SystemExit("Falta resultados/mapas.gpkg: corre primero ./scripts/exportar_mapas.sh")
    pie = pie_fuentes()
    mapa_grilla(pie)
    mapa_densidad(pie)
    print("OK:", OUT / "mapa1_grilla.png", "y", OUT / "mapa2_densidad_paraderos.png")
