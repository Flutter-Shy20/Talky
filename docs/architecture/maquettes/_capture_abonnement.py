#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Produit les captures PNG des planches « Abonnement » (étape 8).

Même méthode que _capture_trajets.py : la planche (format Artifact, sans <!DOCTYPE>)
est enveloppée à la volée dans un document complet, thème clair forcé, chapô, en-têtes
de section, notes et colophon masqués. Chaque PNG isole UNE section de la planche.

Dépendances : google-chrome (headless) et Pillow.
Usage :  python3 _capture_abonnement.py
"""

import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops

ICI = os.path.dirname(os.path.abspath(__file__))
CHROME = "/usr/bin/google-chrome"
LARGEUR = 1720
HAUTEUR_MAX = 3200
MARGE = 18

# (planche, section 1-indexée, png produit — nom attendu par contenu/abonnement-naive.tex)
CIBLES = [
    ("abonnement.html",       1, "abonnement-profil.png"),
    ("abonnement.html",       2, "abonnement-parcours.png"),
    ("abonnement.html",       3, "abonnement-echeance.png"),
    ("abonnement.html",       4, "abonnement-coche.png"),
    ("abonnement-admin.html", 1, "abonnement-admin-reglages.png"),
    ("abonnement-admin.html", 2, "abonnement-admin-plans.png"),
    ("abonnement-admin.html", 3, "abonnement-admin-fiche.png"),
]


def surcharges(section):
    return f"""
    html, body {{ margin: 0; padding: 0; background: #EEF0F7; }}
    .page {{ min-height: 0; padding: {MARGE}px; }}
    .wrap {{ gap: 0; max-width: none; }}
    .masthead, footer.colophon {{ display: none; }}
    .wrap > section {{ display: none; }}
    .wrap > section:nth-of-type({section}) {{ display: flex; }}
    .panel {{ border: none; padding: 0; background: transparent; }}
    .panel > header, .panel > .notes {{ display: none; }}
    *, *::before, *::after {{ animation: none !important; transition: none !important; }}
    """


def enveloppe(source, section):
    contenu = open(source, encoding="utf-8").read()
    tete, corps = contenu.split("</style>", 1)
    return (f'<!DOCTYPE html><html lang="fr" data-theme="light"><head>'
            f'<meta charset="utf-8">{tete}</style>'
            f'<style>{surcharges(section)}</style></head>'
            f'<body>{corps}</body></html>')


def rogner(chemin):
    im = Image.open(chemin).convert("RGB")
    fond = im.getpixel((2, 2))
    boite = ImageChops.difference(im, Image.new("RGB", im.size, fond)).getbbox()
    if not boite:
        return im.size
    g, h, d, b = boite
    g, h = max(0, g - MARGE), max(0, h - MARGE)
    d, b = min(im.width, d + MARGE), min(im.height, b + MARGE)
    im.crop((g, h, d, b)).save(chemin, optimize=True)
    return (d - g, b - h)


def capturer(nom, section, png):
    source = os.path.join(ICI, nom)
    cible = os.path.join(ICI, png)
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "page.html")
        with open(page, "w", encoding="utf-8") as f:
            f.write(enveloppe(source, section))
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
             "--force-color-profile=srgb", "--default-background-color=EEF0F7",
             f"--window-size={LARGEUR},{HAUTEUR_MAX}",
             f"--screenshot={cible}", f"--user-data-dir={tmp}/profil",
             "--virtual-time-budget=2500", f"file://{page}"],
            check=True, capture_output=True, timeout=120,
        )
    return rogner(cible)


def main():
    print("Captures « Abonnement » :")
    for nom, section, png in CIBLES:
        try:
            l, h = capturer(nom, section, png)
            ko = os.path.getsize(os.path.join(ICI, png)) // 1024
            print(f"  {png:34s} {l}x{h}  ({ko} ko)  {nom} §{section}")
        except subprocess.CalledProcessError as e:
            print(f"  {png}: ECHEC — {e.stderr.decode()[:300]}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
