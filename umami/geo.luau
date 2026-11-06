--!nonstrict
local M = {}

local COUNTRIES = {
  AD = "Andorra", AE = "United Arab Emirates", AF = "Afghanistan", AG = "Antigua and Barbuda", AI = "Anguilla",
  AL = "Albania", AM = "Armenia", AO = "Angola", AQ = "Antarctica", AR = "Argentina", AS = "American Samoa",
  AT = "Austria", AU = "Australia", AW = "Aruba", AX = "Åland Islands", AZ = "Azerbaijan",
  BA = "Bosnia and Herzegovina", BB = "Barbados", BD = "Bangladesh", BE = "Belgium", BF = "Burkina Faso",
  BG = "Bulgaria", BH = "Bahrain", BI = "Burundi", BJ = "Benin", BL = "Saint Barthélemy", BM = "Bermuda",
  BN = "Brunei", BO = "Bolivia", BQ = "Caribbean Netherlands", BR = "Brazil", BS = "Bahamas", BT = "Bhutan",
  BV = "Bouvet Island", BW = "Botswana", BY = "Belarus", BZ = "Belize",
  CA = "Canada", CC = "Cocos Islands", CD = "DR Congo", CF = "Central African Republic", CG = "Republic of the Congo",
  CH = "Switzerland", CI = "Côte d'Ivoire", CK = "Cook Islands", CL = "Chile", CM = "Cameroon", CN = "China",
  CO = "Colombia", CR = "Costa Rica", CU = "Cuba", CV = "Cape Verde", CW = "Curaçao", CX = "Christmas Island",
  CY = "Cyprus", CZ = "Czechia",
  DE = "Germany", DJ = "Djibouti", DK = "Denmark", DM = "Dominica", DO = "Dominican Republic", DZ = "Algeria",
  EC = "Ecuador", EE = "Estonia", EG = "Egypt", EH = "Western Sahara", ER = "Eritrea", ES = "Spain", ET = "Ethiopia",
  FI = "Finland", FJ = "Fiji", FK = "Falkland Islands", FM = "Micronesia", FO = "Faroe Islands", FR = "France",
  GA = "Gabon", GB = "United Kingdom", GD = "Grenada", GE = "Georgia", GF = "French Guiana", GG = "Guernsey",
  GH = "Ghana", GI = "Gibraltar", GL = "Greenland", GM = "Gambia", GN = "Guinea", GP = "Guadeloupe",
  GQ = "Equatorial Guinea", GR = "Greece", GS = "South Georgia and the South Sandwich Islands", GT = "Guatemala",
  GU = "Guam", GW = "Guinea-Bissau", GY = "Guyana",
  HK = "Hong Kong", HM = "Heard Island and McDonald Islands", HN = "Honduras", HR = "Croatia", HT = "Haiti",
  HU = "Hungary",
  ID = "Indonesia", IE = "Ireland", IL = "Israel", IM = "Isle of Man", IN = "India",
  IO = "British Indian Ocean Territory", IQ = "Iraq", IR = "Iran", IS = "Iceland", IT = "Italy",
  JE = "Jersey", JM = "Jamaica", JO = "Jordan", JP = "Japan",
  KE = "Kenya", KG = "Kyrgyzstan", KH = "Cambodia", KI = "Kiribati", KM = "Comoros", KN = "Saint Kitts and Nevis",
  KP = "North Korea", KR = "South Korea", KW = "Kuwait", KY = "Cayman Islands", KZ = "Kazakhstan",
  LA = "Laos", LB = "Lebanon", LC = "Saint Lucia", LI = "Liechtenstein", LK = "Sri Lanka", LR = "Liberia",
  LS = "Lesotho", LT = "Lithuania", LU = "Luxembourg", LV = "Latvia", LY = "Libya",
  MA = "Morocco", MC = "Monaco", MD = "Moldova", ME = "Montenegro", MF = "Saint Martin", MG = "Madagascar",
  MH = "Marshall Islands", MK = "North Macedonia", ML = "Mali", MM = "Myanmar", MN = "Mongolia", MO = "Macau",
  MP = "Northern Mariana Islands", MQ = "Martinique", MR = "Mauritania", MS = "Montserrat", MT = "Malta",
  MU = "Mauritius", MV = "Maldives", MW = "Malawi", MX = "Mexico", MY = "Malaysia", MZ = "Mozambique",
  NA = "Namibia", NC = "New Caledonia", NE = "Niger", NF = "Norfolk Island", NG = "Nigeria", NI = "Nicaragua",
  NL = "Netherlands", NO = "Norway", NP = "Nepal", NR = "Nauru", NU = "Niue", NZ = "New Zealand",
  OM = "Oman",
  PA = "Panama", PE = "Peru", PF = "French Polynesia", PG = "Papua New Guinea", PH = "Philippines", PK = "Pakistan",
  PL = "Poland", PM = "Saint Pierre and Miquelon", PN = "Pitcairn Islands", PR = "Puerto Rico", PS = "Palestine",
  PT = "Portugal", PW = "Palau", PY = "Paraguay",
  QA = "Qatar",
  RE = "Réunion", RO = "Romania", RS = "Serbia", RU = "Russia", RW = "Rwanda",
  SA = "Saudi Arabia", SB = "Solomon Islands", SC = "Seychelles", SD = "Sudan", SE = "Sweden", SG = "Singapore",
  SH = "Saint Helena", SI = "Slovenia", SJ = "Svalbard and Jan Mayen", SK = "Slovakia", SL = "Sierra Leone",
  SM = "San Marino", SN = "Senegal", SO = "Somalia", SR = "Suriname", SS = "South Sudan",
  ST = "São Tomé and Príncipe", SV = "El Salvador", SX = "Sint Maarten", SY = "Syria", SZ = "Eswatini",
  TC = "Turks and Caicos Islands", TD = "Chad", TF = "French Southern Territories", TG = "Togo", TH = "Thailand",
  TJ = "Tajikistan", TK = "Tokelau", TL = "Timor-Leste", TM = "Turkmenistan", TN = "Tunisia", TO = "Tonga",
  TR = "Türkiye", TT = "Trinidad and Tobago", TV = "Tuvalu", TW = "Taiwan", TZ = "Tanzania",
  UA = "Ukraine", UG = "Uganda", UM = "U.S. Minor Outlying Islands", US = "United States", UY = "Uruguay",
  UZ = "Uzbekistan",
  VA = "Vatican City", VC = "Saint Vincent and the Grenadines", VE = "Venezuela", VG = "British Virgin Islands",
  VI = "U.S. Virgin Islands", VN = "Vietnam", VU = "Vanuatu",
  WF = "Wallis and Futuna", WS = "Samoa",
  XK = "Kosovo",
  YE = "Yemen", YT = "Mayotte",
  ZA = "South Africa", ZM = "Zambia", ZW = "Zimbabwe",
}

local REGIONS = {
  US = {
    AL = "Alabama", AK = "Alaska", AZ = "Arizona", AR = "Arkansas", CA = "California", CO = "Colorado",
    CT = "Connecticut", DE = "Delaware", DC = "District of Columbia", FL = "Florida", GA = "Georgia",
    HI = "Hawaii", ID = "Idaho", IL = "Illinois", IN = "Indiana", IA = "Iowa", KS = "Kansas", KY = "Kentucky",
    LA = "Louisiana", ME = "Maine", MD = "Maryland", MA = "Massachusetts", MI = "Michigan", MN = "Minnesota",
    MS = "Mississippi", MO = "Missouri", MT = "Montana", NE = "Nebraska", NV = "Nevada", NH = "New Hampshire",
    NJ = "New Jersey", NM = "New Mexico", NY = "New York", NC = "North Carolina", ND = "North Dakota",
    OH = "Ohio", OK = "Oklahoma", OR = "Oregon", PA = "Pennsylvania", RI = "Rhode Island",
    SC = "South Carolina", SD = "South Dakota", TN = "Tennessee", TX = "Texas", UT = "Utah", VT = "Vermont",
    VA = "Virginia", WA = "Washington", WV = "West Virginia", WI = "Wisconsin", WY = "Wyoming",
  },
  CA = {
    AB = "Alberta", BC = "British Columbia", MB = "Manitoba", NB = "New Brunswick",
    NL = "Newfoundland and Labrador", NS = "Nova Scotia", NT = "Northwest Territories", NU = "Nunavut",
    ON = "Ontario", PE = "Prince Edward Island", QC = "Quebec", SK = "Saskatchewan", YT = "Yukon",
  },
  AU = {
    ACT = "Australian Capital Territory", NSW = "New South Wales", NT = "Northern Territory",
    QLD = "Queensland", SA = "South Australia", TAS = "Tasmania", VIC = "Victoria", WA = "Western Australia",
  },
}

local FLAGS = {}
do
  local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    FLAGS[letter] = utf8.char(127397 + letter:byte())
  end
end

local function flag(code)
  local first, second = FLAGS[code:sub(1, 1)], FLAGS[code:sub(2, 2)]
  if code:len() ~= 2 or first == nil or second == nil then
    return ""
  end
  return first .. second
end

local function prefixed(code, name)
  local emoji = flag(code)
  return if emoji == "" then name else `{emoji} {name}`
end

function M.country(code)
  code = tostring(code):upper()
  return prefixed(code, COUNTRIES[code] or code)
end

function M.region(value)
  local country, sub = tostring(value):upper():match("^(%a%a)%-(.+)$")
  if country == nil then
    return tostring(value)
  end
  local name = REGIONS[country] and REGIONS[country][sub]
  local countryName = COUNTRIES[country] or country
  return prefixed(country, if name then `{name}, {countryName}` else `{sub}, {countryName}`)
end

return M
