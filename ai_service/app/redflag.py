"""Coach red-flag filter. Messages that touch medical or safety territory get a
fixed, safe reply and never reach the model (and never consume the user's cap)."""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Flag:
    category: str
    reply: str


_CRISIS = ("If you're thinking about hurting yourself, please reach out now — call or text "
           "your local emergency number, or a crisis line such as 988 in the US. "
           "You deserve support from a real person.")
_MEDICAL = ("That sounds like something a doctor or physio should look at before we train "
            "around it. Stop any exercise that causes sharp pain. Once you've been checked, "
            "I can adapt your plan.")
_ED = ("I want to make sure you're fuelled safely. I can't help with very low intake or "
       "purging. A doctor or registered dietitian can help — and I'm here for training "
       "support anytime.")
_PED = ("I can't advise on steroids, SARMs or other performance-enhancing drugs. "
        "Let's get the most out of training, food and sleep instead.")

_RULES: list[tuple[str, str, re.Pattern[str]]] = [
    ("self_harm", _CRISIS, re.compile(
        r"\b(kill myself|suicid\w*|self[- ]?harm|end my life|hurt myself)\b", re.I)),
    ("cardiac", _MEDICAL, re.compile(
        r"\b(chest pain|heart (pain|attack)|faint(ed|ing)?|pass(ed)? out|"
        r"short(ness)? of breath)\b", re.I)),
    ("injury", _MEDICAL, re.compile(
        r"\b(sharp pain|tor[en] (my )?\w+|broken|fracture|dislocat\w*|numb(ness)?|"
        r"can'?t (move|walk|feel))\b", re.I)),
    ("eating_disorder", _ED, re.compile(
        r"\b(purg\w*|make myself (throw up|vomit)|laxatives?|"
        r"(eat|eating) (nothing|under \d{3} ?(kcal|cal))|[2-9]\d{2} ?(kcal|calories) a day|"
        r"stop eating|starv\w*)\b", re.I)),
    ("peds", _PED, re.compile(r"\b(steroids?|sarms?|trenbolone|anavar|test(osterone)? cycle|"
                              r"hgh|clenbuterol)\b", re.I)),
]

# Outbound safety net: model replies that slipped past the prompt.
_UNSAFE_OUT = re.compile(
    r"\b([1-9]\d{2}|1[01]\d{2}) ?(kcal|calories)( a| per)? day\b|\b(steroid|sarm)s?\b", re.I)


def check_inbound(text: str) -> Flag | None:
    for category, reply, pat in _RULES:
        if pat.search(text):
            return Flag(category, reply)
    return None


def unsafe_outbound(text: str) -> bool:
    return bool(_UNSAFE_OUT.search(text))
