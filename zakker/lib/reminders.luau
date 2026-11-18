-- Shared reminder pool: salawat upon the Prophet ﷺ and azkar.
-- Each item: { kind = "salawat" | "dhikr", title, text, hint }
-- Texts are offline-bundled so reminders work without network.

local M = {}

M.salawat = {
  {
    kind = "salawat",
    title = "ﷺ صَلِّ على النبي",
    text = "اللَّهُمَّ صَلِّ وَسَلِّمْ عَلَى نَبِيِّنَا مُحَمَّد",
    hint = "Salawat upon the Prophet ﷺ",
  },
  {
    kind = "salawat",
    title = "ﷺ صَلِّ على النبي",
    text = "اللَّهُمَّ صَلِّ عَلَى مُحَمَّدٍ وَعَلَى آلِ مُحَمَّدٍ، كَمَا صَلَّيْتَ عَلَى إِبْرَاهِيمَ وَعَلَى آلِ إِبْرَاهِيمَ، إِنَّكَ حَمِيدٌ مَجِيدٌ، اللَّهُمَّ بَارِكْ عَلَى مُحَمَّدٍ وَعَلَى آلِ مُحَمَّدٍ، كَمَا بَارَكْتَ عَلَى إِبْرَاهِيمَ وَعَلَى آلِ إِبْرَاهِيمَ، إِنَّكَ حَمِيدٌ مَجِيدٌ",
    hint = "As-Salat al-Ibrahimiya",
  },
  {
    kind = "salawat",
    title = "ﷺ صَلِّ على النبي",
    text = "صَلَّى اللهُ عَلَيْهِ وَسَلَّم",
    hint = "Short salawat",
  },
  {
    kind = "salawat",
    title = "ﷺ صَلِّ على النبي",
    text = "اللَّهُمَّ صَلِّ وَسَلِّمْ وَبَارِكْ عَلَى سَيِّدِنَا مُحَمَّدٍ وَعَلَى آلِهِ وَصَحْبِهِ أَجْمَعِين",
    hint = "Salawat and salam upon him and his family",
  },
  {
    kind = "salawat",
    title = "ﷺ أكثروا من الصلاة عليه",
    text = "إِنَّ اللَّهَ وَمَلَائِكَتَهُ يُصَلُّونَ عَلَى النَّبِيِّ ۚ يَا أَيُّهَا الَّذِينَ آمَنُوا صَلُّوا عَلَيْهِ وَسَلِّمُوا تَسْلِيمًا",
    hint = "Quran 33:56",
  },
  {
    kind = "salawat",
    title = "ﷺ صَلِّ على النبي",
    text = "اللَّهُمَّ صَلِّ عَلَى مُحَمَّدٍ عَبْدِكَ وَرَسُولِكَ، وَصَلِّ عَلَى الْمُؤْمِنِينَ وَالْمُؤْمِنَاتِ، وَالْمُسْلِمِينَ وَالْمُسْلِمَات",
    hint = "Salawat including the believers",
  },
}

M.azkar = {
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "سُبْحَانَ اللهِ وَبِحَمْدِهِ",
    hint = "100 times — sins forgiven even if like sea foam (Bukhari & Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "لَا إِلَهَ إِلَّا اللهُ وَحْدَهُ لَا شَرِيكَ لَهُ، لَهُ الْمُلْكُ وَلَهُ الْحَمْدُ، وَهُوَ عَلَى كُلِّ شَيْءٍ قَدِير",
    hint = "100 times in the morning — best of deeds (Bukhari & Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 سيد الاستغفار",
    text = "اللَّهُمَّ أَنْتَ رَبِّي لَا إِلَهَ إِلَّا أَنْتَ، خَلَقْتَنِي وَأَنَا عَبْدُكَ، وَأَنَا عَلَى عَهْدِكَ وَوَعْدِكَ مَا اسْتَطَعْتُ، أَعُوذُ بِكَ مِنْ شَرِّ مَا صَنَعْتُ، أَبُوءُ لَكَ بِنِعْمَتِكَ عَلَيَّ، وَأَبُوءُ بِذَنْبِي فَاغْفِرْ لِي، فَإِنَّهُ لَا يَغْفِرُ الذُّنُوبَ إِلَّا أَنْت",
    hint = "Whoever says it in the morning/evening with certainty (Bukhari)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "أَسْتَغْفِرُ اللهَ وَأَتُوبُ إِلَيْهِ",
    hint = "The Prophet ﷺ sought forgiveness 100 times a day (Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "سُبْحَانَ اللهِ، وَالْحَمْدُ لِلَّهِ، وَلَا إِلَهَ إِلَّا اللهُ، وَاللهُ أَكْبَر",
    hint = "Most beloved words to Allah (Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "لَا حَوْلَ وَلَا قُوَّةَ إِلَّا بِالله",
    hint = "A treasure among the treasures of Paradise (Bukhari & Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "حَسْبِيَ اللهُ لَا إِلَهَ إِلَّا هُوَ، عَلَيْهِ تَوَكَّلْتُ، وَهُوَ رَبُّ الْعَرْشِ الْعَظِيم",
    hint = "7 times morning and evening (morning/evening adhkar)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "رَضِيتُ بِاللهِ رَبًّا، وَبِالْإِسْلَامِ دِينًا، وَبِمُحَمَّدٍ ﷺ نَبِيًّا",
    hint = "3 times — Paradise becomes due (morning/evening adhkar)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "بِسْمِ اللهِ الَّذِي لَا يَضُرُّ مَعَ اسْمِهِ شَيْءٌ فِي الْأَرْضِ وَلَا فِي السَّمَاءِ، وَهُوَ السَّمِيعُ الْعَلِيم",
    hint = "3 times — nothing harms him (morning/evening adhkar)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "أَعُوذُ بِكَلِمَاتِ اللهِ التَّامَّاتِ مِنْ شَرِّ مَا خَلَق",
    hint = "3 times in the evening (morning/evening adhkar)",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر الصباح",
    text = "اللَّهُمَّ بِكَ أَصْبَحْنَا، وَبِكَ أَمْسَيْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ النُّشُور",
    hint = "Morning dhikr",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر المساء",
    text = "اللَّهُمَّ بِكَ أَمْسَيْنَا، وَبِكَ أَصْبَحْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ الْمَصِير",
    hint = "Evening dhikr",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "يَا حَيُّ يَا قَيُّومُ، بِرَحْمَتِكَ أَسْتَغِيثُ، أَصْلِحْ لِي شَأْنِي كُلَّهُ، وَلَا تَكِلْنِي إِلَى نَفْسِي طَرْفَةَ عَيْن",
    hint = "Morning/evening counsel of the Prophet ﷺ",
  },
  {
    kind = "dhikr",
    title = "🤲 آية الكرسي",
    text = "اللهُ لَا إِلَهَ إِلَّا هُوَ الْحَيُّ الْقَيُّومُ — فَاقْرَأْ آيَةَ الْكُرْسِيّ (البقرة ٢٥٥)",
    hint = "After every prayer — nothing blocks Paradise but death",
  },
  {
    kind = "dhikr",
    title = "🤲 ذِكر",
    text = "سُبْحَانَ اللهِ وَبِحَمْدِهِ، عَدَدَ خَلْقِهِ، وَرِضَا نَفْسِهِ، وَزِنَةَ عَرْشِهِ، وَمِدَادَ كَلِمَاتِهِ",
    hint = "3 times in the morning — outweighs hours of dhikr (Muslim)",
  },
  {
    kind = "dhikr",
    title = "🤲 المعوذات",
    text = "اقْرَأْ: ﴿قُلْ هُوَ اللهُ أَحَدٌ﴾ وَالْمُعَوِّذَتَيْنِ — ثَلَاثَ مَرَّاتٍ صَبَاحًا وَمَسَاءً",
    hint = "Suffice you against everything (morning/evening adhkar)",
  },
}

--- Combined pool honoring the plugin settings.
---@param salawat_on boolean
---@param azkar_on boolean
---@return table array of items
function M.collect(salawat_on, azkar_on)
  local out = {}
  if salawat_on then
    for _, item in ipairs(M.salawat) do
      table.insert(out, item)
    end
  end
  if azkar_on then
    for _, item in ipairs(M.azkar) do
      table.insert(out, item)
    end
  end
  return out
end

return M
