#!/usr/bin/env ruby
# encoding: utf-8
# Рыночный ориентир для недвижимости: сравнение по ТИПУ объекта и МЕСТУ — город, а для деревень район,
# не область (20.10.2026: по области квартира в Слуцке сравнивалась с пригородом Минска — ориентир на треть выше).
# Источники: Kufar (поиск по категории и коду города/района, app/kufar_areas.json) и realt.by
# (страницы каталога области, по правилам сайта для роботов — только адреса без фильтров и страницы до 10-й;
# отбор по городу/району — у нас). Где у обеих сторон известна площадь, считаем цену за квадратный метр.
require 'json'
require 'shellwords'
require 'erb'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

UA    = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
DIR   = File.dirname(File.expand_path(__FILE__))
MIN_N = 4
VER   = 2            # версия правил: ориентиры старой версии пересчитываем
BUDGET = (ENV["MR_BUDGET"] || 8 * 60).to_i   # секунд на прогон — остальное доделает следующий

# Типы, у которых есть сопоставимый рынок частных объявлений.
# Склады, производства и имущественные комплексы сюда не входят осознанно:
# таких объектов в открытой продаже почти нет, ориентир вышел бы выдуманным.
# kufar — категория Kufar, realt — разделы realt.by, term — слово для ссылки «похожие предложения».
TYPES = {
  'Гаражи'                    => { kufar: 1030, realt: %w[garage],          term: 'гараж' },
  'Машиноместа'               => { kufar: 1030, realt: %w[garage],          term: 'машиноместо' },
  'Дома'                      => { kufar: 1020, realt: %w[cottages dachi],  term: 'дом' },
  'Земельные участки'         => { kufar: 1080, realt: %w[plots],           term: 'участок' },
  'Квартиры и комнаты'        => { kufar: 1010, realt: %w[flats],           term: 'квартира' },
  'Коммерческая недвижимость' => { kufar: 1050, realt: %w[offices shops],   term: 'помещение' }
}.freeze

# области: код Kufar → адрес раздела области на realt.by (Минск — без приставки)
REALT_REGION = { '1' => 'brest-region', '2' => 'gomel-region', '3' => 'grodno-region', '4' => 'mogilev-region',
                 '5' => 'minsk-region', '6' => 'vitebsk-region', '7' => '' }.freeze
KUFAR = JSON.parse(File.read(File.join(DIR, 'kufar_areas.json')))

def get(url)
  `curl -sS --compressed -m 25 -A #{Shellwords.escape(UA)} #{Shellwords.escape(url)} 2>/dev/null`.to_s.force_encoding('UTF-8')
end

def norm(s)
  s.to_s.downcase.tr('ё', 'е').strip
end

def median(a)
  s = a.sort
  s.size.odd? ? s[s.size / 2] : ((s[s.size / 2 - 1] + s[s.size / 2]) / 2.0)
end

# Место лота: область (код Kufar), город, район
def place(l)
  addr = l['location'].to_s
  reg = l['region'].to_s.empty? ? region_of(addr).to_s : l['region'].to_s
  rgn = reg =~ /\Aг\.\s*Минск/ ? '7' : KUFAR.find { |k, v| k != '_' && norm(v['name'])[0, 6] == norm(reg)[0, 6] }&.first
  city = addr[/(?:\A|[\s,])г\.\s*([А-ЯЁ][а-яё]+(?:[- ][А-ЯЁ][а-яё]+)?)/, 1]
  dist = addr[/([А-ЯЁ][а-яё]+(?:ий|ой))\s+(?:р-н|район)/, 1]
  [rgn, city, dist]
end

# Код города/района на Kufar: сам город, иначе «Х район», иначе районный центр (Ушачский → Ушачи)
def kufar_area(rgn, city, dist)
  areas = (KUFAR[rgn] || {})['areas'] || {}
  return [nil, 'Минск'] if rgn == '7'
  if city && (c = areas.find { |n, _| norm(n) == norm(city) })
    return [c[1], c[0]]
  end
  return nil unless dist
  if (c = areas.find { |n, _| norm(n) == norm("#{dist} район") })
    return [c[1], c[0]]
  end
  best = areas.reject { |n, _| n =~ /район|Другие/ }.map do |n, v|
    lcp = norm(n).chars.zip(norm(dist).chars).take_while { |a, b| a == b }.size
    [lcp, n, v]
  end.max_by(&:first)
  best && best[0] >= [4, best[1].size - 1].min ? [best[2], best[1]] : nil
end

def kufar_ads(cat, rgn, ar)
  url = "https://api.kufar.by/search-api/v2/search/rendered-paginated?size=100&cat=#{cat}&typ=sell&rgn=#{rgn}" + (ar ? "&ar=#{ar}" : '')
  ads = (JSON.parse(get(url))['ads'] || []) rescue []
  ads.map do |a|
    pr = (a['ad_parameters'] || [])
    par = ->(k) { (pr.find { |x| x['p'] == k } || {})['vl'] }
    { p: a['price_byn'].to_i / 100.0, a: par.('size').to_s.tr(',', '.')[/\d+(\.\d+)?/]&.to_f, rooms: par.('rooms').to_s[/\d+/]&.to_i }
  end
end

# realt.by: объявления раздела по области — копим в data/realt.json, обновляем раз в неделю
REALT_FILE = File.join(DIR, '..', 'data', 'realt.json')
REALT = (JSON.parse(File.read(REALT_FILE)) rescue {})
REALT_DAYS = 7
$realt_dirty = false

def realt_ads(rgn, sec)
  key = "#{REALT_REGION[rgn]}/#{sec}"
  c = REALT[key]
  return c['ads'] if c && c['at'].to_i > Time.now.to_i - REALT_DAYS * 86_400
  base = "https://realt.by#{REALT_REGION[rgn].empty? ? '' : '/' + REALT_REGION[rgn]}/sale/#{sec}/"
  ads = []
  (1..10).each do |pg|
    h = get(pg == 1 ? base : "#{base}?page=#{pg}")
    js = h[/<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/m, 1] or break
    pp = (JSON.parse(js)['props']['pageProps'] rescue {})
    obs = pp['objects'] || []
    obs.each do |o|
      byn = (o['priceRates'] || {})['933'].to_f
      next unless byn.positive?
      ads << { 'p' => byn, 'a' => o['areaTotal'], 'rooms' => o['rooms'], 'town' => o['townName'], 'dist' => o['stateDistrictName'] }
    end
    sleep 2
    break if obs.size < 30 || ads.size >= pp['totalCount'].to_i
  end
  return (c ? c['ads'] : []) if ads.empty?   # сайт не ответил — берём прошлую копию
  REALT[key] = { 'at' => Time.now.to_i, 'ads' => ads }
  $realt_dirty = true
  ads
end

ROOMS = { 'одно' => 1, 'двух' => 2, 'трех' => 3, 'трёх' => 3, 'четырех' => 4, 'четырёх' => 4 }.freeze
def rooms_of(name)
  n = name.to_s.downcase
  (n[/(\d)-?\s*комн/, 1] || ROOMS.find { |k, _| n.include?("#{k}комнатн") }&.last)&.to_i
end

require_relative 'regions'
require_relative 'store'
# Считаем только активные лоты без свежего ориентира: новые, старой версии правил и проверенные
# больше REFRESH_DAYS назад. Иначе каждый прогон — сотни запросов.
REFRESH_DAYS = 14
NOW = Time.now.to_i
lots = Store.load
found = 0
skipped = 0

# Здания, цеха и комплексы с рядовыми объявлениями не сравниваем: «здание гаражей
# на 2000 м²» не одиночный гараж, а производственное помещение не офис.
def kind_of(name)
  n = name.to_s.downcase
  return nil if n =~ /здани|комплекс|цех|производств|склад|строени|сооружени/
  return nil if n =~ /аренд|(?<![а-яё])дол[яиейю](?![а-яё])/   # право аренды и доли — не сам объект
  return 'Квартиры и комнаты' if n =~ /квартир|комнат/
  return 'Машиноместа' if n =~ /машино-?мест/
  return 'Гаражи' if n =~ /\Aгараж|гаражн\S* бокс/
  return 'Земельные участки' if n =~ /\Aземельн/
  return 'Дома' if n =~ /жило[йго]+ дом|садов|дач|коттедж/
  return 'Коммерческая недвижимость' if n =~ /помещени|офис|магазин/
  nil
end

todo = lots.each_index.select do |i|
  l = lots[i]
  l['section'] == 'nedvizhimost' && l['status'] == 'active' &&
    (l['market_rv'].to_i != VER || l['market_at'].to_i <= NOW - REFRESH_DAYS * 86_400)
end.sort_by { |i| lots[i]['market_rv'].to_i == VER ? lots[i]['market_at'].to_i : 0 }

t0 = Time.now
todo.each do |i|
  break if Time.now - t0 > BUDGET
  l = lots[i]
  l['market_at'] = NOW
  l['market_rv'] = VER
  l.delete('market')
  kind = l['sub_ru'] || kind_of(l['name'])
  spec = TYPES[kind]
  rgn, city, dist = place(l)
  area = spec && rgn && kufar_area(rgn, city, dist)
  if spec.nil? || area.nil?
    skipped += 1
    next
  end
  ar, where = area

  kf = kufar_ads(spec[:kufar], rgn, ar)
  rl = spec[:realt].flat_map { |sec| realt_ads(rgn, sec) }.select do |a|
    if rgn == '7' then true
    elsif city then norm(a['town']) == norm(city)
    else dist && norm(a['dist']) == norm(dist)
    end
  end.map { |a| { p: a['p'].to_f, a: a['a']&.to_f, rooms: a['rooms'], realt: true } }

  ads = (kf + rl).select { |a| a[:p] > 300 && a[:p] < 3_000_000 }
  if kind == 'Квартиры и комнаты' && (r = rooms_of(l['name']))
    same = ads.select { |a| a[:rooms] == r }
    ads = same if same.size >= MIN_N
  end
  # площадь похожая — от половины до двойной, если таких объявлений хватает: помещение 30 м² не сравниваем с 500 м²
  if (la = l['area_num'].to_f) > 5
    near = ads.select { |a| a[:a].to_f.between?(la / 2, la * 2) }
    ads = near if near.size >= MIN_N
  end
  next if ads.size < MIN_N

  s = ads.map { |a| a[:p] }.sort
  nk = ads.count { |a| !a[:realt] }
  src = [nk.positive? ? 'kufar.by' : nil, nk < ads.size ? 'realt.by' : nil].compact.join(' и ')
  m = { 'median' => median(s).round, 'low' => s[(s.size * 0.25).floor].round,
        'high' => s[(s.size * 0.75).floor].round, 'n' => s.size,
        'query' => "#{spec[:term]}, #{where}", 'source' => src,
        'link' => 'https://www.kufar.by/l?query=' + ERB::Util.url_encode("#{spec[:term]} #{where}") }
  # цена за м² — только если площадь есть и у лота, и у объявлений
  sqm = ads.select { |a| a[:a].to_f > 5 }.map { |a| a[:p] / a[:a] }
  if sqm.size >= MIN_N && l['area_num'].to_f > 5
    m['sqm'] = median(sqm.sort).round
    m['sqm_n'] = sqm.size
    m['lot_sqm'] = (l['price'].to_f / l['area_num'].to_f).round
  end
  l['market'] = m
  found += 1
  STDERR.print "\r#{i + 1}/#{lots.size}, ориентиров #{found}"
  sleep 0.6
end
STDERR.puts

Store.save(lots)
File.write(REALT_FILE, JSON.generate(REALT)) if $realt_dirty
STDERR.puts "недвижимость: ориентир у #{found}, пропущено (тип или место) #{skipped}, в очереди было #{todo.size}"
