#!/usr/bin/env ruby
# encoding: utf-8
require 'json'
require 'time'
require 'digest'
require 'shellwords'
require_relative 'store'
require_relative 'regions'

module FindsRealty
  module_function

  UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
  DIR = File.expand_path(__dir__)
  KUFAR = JSON.parse(File.read(File.join(DIR, 'kufar_areas.json')))
  CACHE = File.join(Store::DATA, 'finds_realty_cache.json')
  MIN_PROFIT = 3000
  MIN_PCT = 20
  BIG_PROFIT = 10_000
  PAYBACK = 8
  BIG_DISCOUNT = 40
  SELL_PCT = 0.97
  SELL_COSTS = 500
  RENT_IDLE = 0.85
  RESERVE = { 'хорошее' => 0.05, nil => 0.15, 'требует ремонта' => 0.2, 'аварийное' => 0.4 }.freeze

  CITIES = {
    'Минск' => 'minsk', 'Гомель' => 'gomel', 'Гродно' => 'grodno', 'Витебск' => 'vitebsk', 'Могилев' => 'mogilev',
    'Брест' => 'brest', 'Бобруйск' => 'bobruisk', 'Барановичи' => 'baranovichi', 'Борисов' => 'borisov', 'Пинск' => 'pinsk',
    'Мозырь' => 'mozyr', 'Лида' => 'lida', 'Орша' => 'orsha', 'Солигорск' => 'soligorsk', 'Новополоцк' => 'novopolotsk',
    'Молодечно' => 'molodechno', 'Полоцк' => 'polotsk', 'Жлобин' => 'zhlobin', 'Речица' => 'rechitsa', 'Жодино' => nil,
    'Светлогорск' => 'svetlogorsk', 'Слуцк' => nil, 'Кобрин' => 'kobrin', 'Слоним' => 'slonim', 'Волковыск' => 'volkovysk',
    'Калинковичи' => 'kalinkovichi', 'Сморгонь' => 'smorgon', 'Рогачев' => 'rogachev', 'Дзержинск' => 'dzerzhinsk',
    'Осиповичи' => 'osipovichi', 'Горки' => 'gorki', 'Береза' => 'bereza', 'Новогрудок' => 'novogrudok', 'Вилейка' => 'vileyka',
    'Смолевичи' => 'smolevichi', 'Лунинец' => 'luninets', 'Кричев' => 'krichev', 'Ивацевичи' => 'ivatsevichi', 'Марьина Горка' => nil
  }.freeze
  CENTERS = { 'Минск' => [53.902, 27.561, 40], 'Брест' => [52.097, 23.734, 25], 'Гродно' => [53.669, 23.813, 25],
              'Гомель' => [52.441, 30.988, 25], 'Могилев' => [53.895, 30.331, 25], 'Витебск' => [55.184, 30.202, 25] }.freeze

  NEAR_DISTRICTS = {
    'Минск' => %w[Минский Дзержинский Смолевичский Логойский Пуховичский Червенский Молодечненский],
    'Брест' => %w[Брестский Жабинковский Каменецкий Малоритский],
    'Гродно' => %w[Гродненский Щучинский Берестовицкий],
    'Гомель' => %w[Гомельский Кошелевский Ветковский Добрушский Речицкий Лоевский],
    'Могилев' => %w[Могилевский Шкловский Белыничский Чаусский Быховский Круглянский],
    'Витебск' => %w[Витебский Шумилинский Бешенковичский Лиозненский Городокский Сенненский]
  }.freeze

  TYPES = { 'kv' => 'Квартира', 'dom' => 'Дом, дача', 'garage' => 'Гараж', 'land' => 'Участок', 'comm' => 'Коммерция', 'big' => 'Здание, склад' }.freeze
  KCAT = { 'kv' => 1010, 'dom' => 1020, 'garage' => 1030, 'land' => 1080, 'comm' => 1050 }.freeze

  def type_of(name)
    n = name.to_s.downcase
    return nil if n =~ /\bдол[яиюей]\b|\b\d+\/\d+\b/
    return 'big' if n =~ /здани|комплекс|склад|цех|производств|ангар|сооружени|строени|недострой|незаверш|мастерск|котельн|ферм|база\b/
    return 'kv' if n =~ /квартир/
    return 'garage' if n =~ /гараж|машино-?мест/
    return 'dom' if n =~ /жил\S*\s+дом|\bдом\b|коттедж|дач[аи]|садов\S* дом/
    return 'comm' if n =~ /магазин|офис|торгов|кафе|ресторан|столов|помещени|павильон|киоск/
    return 'land' if n =~ /земельн|участ/
    nil
  end

  def norm(s)
    s.to_s.downcase.tr('ё', 'е').strip
  end

  def dist_km(a, b)
    r = Math::PI / 180
    x = (b[1] - a[1]) * r * Math.cos((a[0] + b[0]) / 2 * r)
    y = (b[0] - a[0]) * r
    Math.sqrt(x * x + y * y) * 6371
  end

  def where(l)
    addr = l['location'].to_s
    city = CITIES.keys.find { |c| addr =~ /(?:\A|[\s,(])г\.\s*#{Regexp.escape(c).gsub('е', '[её]')}(?![а-яё])/i }
    city ||= 'Минск' if l['region'].to_s =~ /\Aг\.\s*Минск/
    return [city, nil] if city
    g = l['geo']
    return nil unless g.is_a?(Array) && g[0]
    near = CENTERS.find { |_, (la, lo, km)| dist_km([la, lo], g) <= km } or return nil
    dist = addr[/([А-ЯЁ][а-яё]+(?:ий|ой))\s+(?:р-н|район)/, 1]
    return nil if dist && !NEAR_DISTRICTS[near[0]].include?(dist)
    [nil, near[0]]
  end

  def cache
    @cache ||= (JSON.parse(File.read(CACHE)) rescue {})
  end

  def save_cache
    now = Time.now.to_i
    cache.reject! { |_, v| v['at'].to_i < now - 7 * 86_400 }
    File.write(CACHE, JSON.generate(cache))
  end

  def get(url)
    `curl -sS --compressed -m 30 -A #{Shellwords.escape(UA)} #{Shellwords.escape(url)} 2>/dev/null`.to_s.force_encoding('UTF-8')
  end

  def area(l, city, center)
    reg = l['region'].to_s
    rgn = reg =~ /\Aг\.\s*Минск/ || city == 'Минск' ? '7' : KUFAR.find { |k, v| k != '_' && norm(v['name'])[0, 6] == norm(reg)[0, 6] }&.first
    return nil unless rgn
    return ['7', nil, 'Минск'] if rgn == '7'
    areas = KUFAR[rgn]['areas']
    if city && (c = areas.find { |n, _| norm(n) == norm(city) })
      return [rgn, c[1], c[0]]
    end
    dist = l['location'].to_s[/([А-ЯЁ][а-яё]+(?:ий|ой))\s+(?:р-н|район)/, 1]
    if dist && (c = areas.find { |n, _| norm(n) == norm("#{dist} район") })
      return [rgn, c[1], c[0]]
    end
    cd = { 'Минск' => 'Минский район', 'Брест' => 'Брестский район', 'Гродно' => 'Гродненский район', 'Гомель' => 'Гомельский район',
           'Могилев' => 'Могилевский район', 'Витебск' => 'Витебский район' }[center]
    if cd && (c = areas.find { |n, _| norm(n) == norm(cd) })
      return [rgn, c[1], c[0]]
    end
    nil
  end

  def kufar_ads(cat, typ, rgn, ar)
    key = "#{cat}/#{typ}/#{rgn}/#{ar}"
    c = cache[key]
    return c['ads'] if c && c['at'].to_i > Time.now.to_i - 3 * 86_400
    url = "https://api.kufar.by/search-api/v2/search/rendered-paginated?size=200&cat=#{cat}&typ=#{typ}&rgn=#{rgn}" + (ar ? "&ar=#{ar}" : '')
    raw = (JSON.parse(get(url))['ads'] rescue nil)
    sleep 1
    return (c ? c['ads'] : []) unless raw
    ads = raw.map do |a|
      pr = a['ad_parameters'] || []
      par = ->(k) { (pr.find { |x| x['p'] == k } || {})['vl'] }
      num = ->(k) { par.(k).to_s.tr(',', '.')[/\d+(\.\d+)?/]&.to_f }
      { 'p' => a['price_byn'].to_i / 100.0, 'pu' => a['price_usd'].to_i / 100.0, 'a' => num.('size') || num.('square_meter'), 'land' => num.('size_area'),
        'rooms' => par.('rooms').to_s[/\d+/]&.to_i, 'rep' => par.('flat_repair'), 'pt' => par.('property_type'),
        'fl' => Array(par.('floor')).first.to_s[/\d+/]&.to_i, 'y' => par.('year_built').to_s[/\d{4}/]&.to_i,
        's' => a['subject'].to_s[0, 80], 'u' => a['ad_link'] }
    end.select { |a| a['p'] > 0 }
    cache[key] = { 'at' => Time.now.to_i, 'ads' => ads }
    ads
  end

  def deal_ratio(city)
    slug = CITIES[city] || 'minsk'
    key = "realt/#{slug}"
    c = cache[key]
    unless c && c['at'].to_i > Time.now.to_i - 7 * 86_400
      h = get("https://realt.by/statistics/#{slug}/")
      js = h[/<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/m, 1]
      d = ((JSON.parse(js)['props']['pageProps']['statisticsTownData'] || {}) rescue {})
      deals = d['priceAndDealsStatistics'] || []
      asks = d['newPriceStatisticsSecondary'] || []
      last = deals.last
      r = last && last['price'].to_f > 0 ? { 'deal' => last['price'].to_f.round, 'm' => last['date'].to_s[0, 7], 'n' => last['count'] } : nil
      cache[key] = c = { 'at' => Time.now.to_i, 'r' => r }
      sleep 2
    end
    c['r']
  end

  def text(l)
    ([l['name']] + Store.details(l['key']).flat_map { |s| (s['rows'] || []).map { |r| r.join(' ') } }).join(' ')
  end

  def area_m2(l, t)
    if t == 'land'
      tx = text(l)
      ha = tx[/(\d+(?:[.,]\d+)?)\s*га\b/i, 1]
      return (ha.tr(',', '.').to_f * 100).round(1) if ha
      so = tx[/(\d+(?:[.,]\d+)?)\s*сот/i, 1]
      return so&.tr(',', '.')&.to_f
    end
    a = l['area_num'].to_f
    return a if a.positive?
    m = text(l)[/(?:общ\S*\s+)?площад\S*[^0-9]{0,25}(\d+(?:[.,]\d+)?)\s*(?:кв\.?\s*м|м2|м²)/i, 1]
    m && m.tr(',', '.').to_f
  end

  def condition(tx)
    return 'аварийное' if tx =~ /аварийн|разрушен|ветх|непригодн|без\s+крыш/i
    return 'требует ремонта' if tx =~ /требу\S*\s+(?:капитальн\S*\s+|текущ\S*\s+|косметическ\S*\s+)?ремонт|без\s+отделк|без\s+ремонт/i
    return 'хорошее' if tx =~ /хорош\S*\s+состояни|удовлетворительн\S*\s+состояни|евроремонт|с\s+ремонтом|отличн\S*\s+состояни/i
    nil
  end

  def rooms_of(name)
    n = name.to_s.downcase
    (n[/(\d)\s*-?\s*(?:х\s*)?комн/, 1] || { 'одно' => 1, 'двух' => 2, 'трех' => 3, 'трёх' => 3, 'четырех' => 4 }.find { |k, _| n.include?("#{k}комнатн") }&.last)&.to_i
  end

  def med(a)
    s = a.sort
    s[s.size / 2]
  end

  def q(a, f)
    s = a.sort
    s[(s.size * f).floor.clamp(0, s.size - 1)]
  end

  def comps(t, ads, area, cond, rooms)
    repair = cond == 'хорошее' ? /космет|евро|дизайн|хорош|отличн/i : cond ? /требует|без|нет/i : nil
    steps = []
    steps << ['тот же ремонт, комнаты, площадь ±40%', ->(a) { a['rep'].to_s =~ repair && a['rooms'] == rooms }, 0.4] if t == 'kv' && repair && rooms
    steps << ['тот же ремонт, площадь ±40%', ->(a) { a['rep'].to_s =~ repair }, 0.4] if t == 'kv' && repair
    steps << ['комнаты, площадь ±40%', ->(a) { a['rooms'] == rooms }, 0.4] if t == 'kv' && rooms
    steps << ['площадь ±40%', ->(_) { true }, 0.4]
    steps << ['площадь ±60%', ->(_) { true }, 0.6]
    steps.each_with_index do |(how, ok, k), i|
      sel = ads.select { |a| ok.(a) && (t == 'garage' && !area ? true : a['a'].to_f.positive? && area && (a['a'] - area).abs <= area * k) }
      return [sel, how, i] if sel.size >= 3
    end
    t == 'garage' && ads.size >= 3 ? [ads, 'все гаражи', 9] : nil
  end

  def history(lots)
    now = Time.now.to_i
    mk = Hash.new { |h, k| h[k] = [] }
    big = Hash.new { |h, k| h[k] = [] }
    lots.each do |l|
      r = l['result']
      next unless l['section'] == 'nedvizhimost' && r.is_a?(Hash) && %w[sold single].include?(r['st']) && r['price'].to_f.positive?
      next unless r['at'].to_i > now - 548 * 86_400
      t = type_of(l['name']) or next
      st = (r['start'] || l['price']).to_f
      mk[t] << r['price'].to_f / st if st.positive?
      a = l['area_num'].to_f
      big[l['region']] << { 'm2' => r['price'].to_f / a, 'n' => l['name'].to_s[0, 70], 'p' => r['price'].to_f.round, 'a' => a, 'at' => r['at'] } if t == 'big' && a > 20
    end
    [mk.transform_values { |v| v.sort! && { 'n' => v.size, 'med' => v[v.size / 2].round(2), 'q75' => v[(v.size * 0.75).floor].round(2) } }, big]
  end

  def run(lots, finds_mod)
    now = Time.now.to_i
    mk, big = history(lots)
    out = []
    stat = Hash.new(0)
    lots.select { |l| l['status'] == 'active' && l['section'] == 'nedvizhimost' && l['req_to'].to_i > now && l['price'].to_f.positive? }.each do |l|
      stat['недвижимость'] += 1
      (stat['belauction (текущая ставка)'] += 1; next) if l['platform'] == 'belauction.by'
      t = type_of(l['name']) or (stat['доля или прочее'] += 1; next)
      city, center = where(l) || (stat['не наш район'] += 1; next)
      tx = text(l)
      area = area_m2(l, t)
      (stat['нет площади'] += 1; next) if !area && t != 'garage'
      cond = condition(tx)
      k = mk[t] && mk[t]['n'] >= 10 ? mk[t] : { 'n' => 0, 'q75' => 1.0, 'med' => 1.0 }
      buy = (l['price'].to_f * [k['q75'], 1.0].max).round
      costs = finds_mod.costs(l, buy)
      total = buy + costs['fee'] + costs['fee_abs'] + costs['vat']
      base = { 'kind' => 'realty', 'type' => t, 'key' => l['key'], 'id' => l['id'] || (l['key'].start_with?('ipm-') ? "ipm-#{Digest::MD5.hexdigest(l['key'])[0, 8]}" : Store.fname(l['key'])), 'name' => l['name'], 'platform' => l['platform'], 'url' => l['url'],
               'region' => l['region'], 'city' => place_of(l['location'], l['region']), 'location' => l['location'], 'req_to' => l['req_to'],
               'near' => city || "#{center} (#{CENTERS[center][2]} км)", 'area' => area&.round(1), 'cond' => cond,
               'start' => l['price'].to_f.round, 'markup' => k, 'buy' => buy, 'costs' => costs, 'total' => total.round,
               'flags' => [('за 1 базовую' if l['price'].to_f <= 50), ('обязательства покупателя' if tx =~ /обязательств\S*\s+покупател|создани\S*\s+рабоч\S*\s+мест|реконструкц\S*\s+в\s+течени|условия\s+продаж/i),
                           ('аренда/обременение' if tx =~ /обременен|арест|ипотек|сдан\S*\s+в\s+аренд|договор\S*\s+аренды/i),
                           ('зарегистрированы жильцы' if tx =~ /зарегистрирован\S*\s+(?:по\s+месту\s+жительства|граждан|лиц)|проживают|прописан/i)].compact }
      if t == 'big'
        all = big[l['region']] || []
        pool = all.select { |x| x['a'].between?(area / 3, area * 3) }
        pool = all if pool.size < 3
        (stat['здания: мало итогов в области'] += 1; next) if pool.size < 3
        m2 = med(pool.map { |x| x['m2'] })
        my = total / area
        disc = ((1 - my / m2) * 100).round
        out << base.merge('method' => 'torgi', 'hist' => { 'n' => pool.size, 'm2' => m2.round, 'ex' => pool.sort_by { |x| -x['at'].to_i }.first(3) },
                          'my_m2' => my.round, 'discount' => disc, 'profit' => 0, 'pct' => 0, 'find' => disc >= BIG_DISCOUNT, 'trust' => 'низкая')
        stat['оценено'] += 1
        next
      end
      ar = area(l, city, center) or (stat['нет кода места на Kufar'] += 1; next)
      if t == 'comm'
        ads = kufar_ads(KCAT[t], 'let', ar[0], ar[1]).select { |a| a['p'] < 50_000 }
        cs = comps(t, ads, area, nil, nil) or (stat['мало объявлений'] += 1; next)
        sel, how, step = cs
        m2 = sel.map { |a| a['p'] / a['a'] }
        rent = (q(m2, 0.25) * area).round
        rent_mid = (med(m2) * area).round
        reserve = (total * RESERVE[cond] * 0.5).round
        year = rent * 12 * RENT_IDLE
        pay = ((total + reserve) / year).round(1)
        out << base.merge('method' => 'rent', 'rent' => rent, 'rent_mid' => rent_mid, 'rent_m2' => q(m2, 0.25).round(1), 'reserve' => reserve,
                          'payback' => pay, 'yield' => (year / (total + reserve) * 100).round(1), 'income' => year.round,
                          'profit' => year.round, 'pct' => (year / (total + reserve) * 100).round, 'market' => mk_info(sel, how, ar[2], 'let', t, area),
                          'find' => pay <= PAYBACK, 'trust' => trust(sel.size, step, center))
        stat['оценено'] += 1
        next
      end
      ads = kufar_ads(KCAT[t], 'sell', ar[0], ar[1])
      ads = ads.map { |a| a.merge('a' => a['land']) } if t == 'land'
      cs = comps(t, ads, area, cond, t == 'kv' ? rooms_of(l['name']) : nil) or (stat['мало объявлений'] += 1; next)
      sel, how, step = cs
      unit = t == 'garage' && (!area || step == 9)
      per = unit ? sel.map { |a| a['p'] } : sel.map { |a| a['p'] / a['a'] }
      ask = unit ? med(per) : med(per) * area
      low = unit ? q(per, 0.25) : q(per, 0.25) * area
      dr = t == 'kv' ? deal_ratio(city || center) : nil
      usd = ads.select { |a| a['pu'].to_f > 0 && a['a'].to_f > 10 }.map { |a| a['pu'] / a['a'] }
      ratio = dr && usd.size >= 5 ? (dr['deal'] / med(usd)).round(2).clamp(0.6, 1.0) : 0.9
      dr = dr.merge('ask' => med(usd).round, 'na' => usd.size) if dr && usd.size >= 5
      mkt = (ask * ratio).round
      sell = (mkt * SELL_PCT - SELL_COSTS).round
      reserve = (mkt * RESERVE[cond]).round
      profit = sell - total - reserve
      pct = (profit * 100.0 / total).round
      out << base.merge('method' => 'resale', 'market' => mk_info(sel, how, ar[2], 'sell', t, area).merge('ask' => ask.round, 'low' => (low * ratio).round, 'ratio' => ratio, 'deals' => dr),
                        'mkt' => mkt, 'sell' => sell, 'reserve' => reserve, 'profit' => profit.round, 'pct' => pct,
                        'find' => (profit >= MIN_PROFIT && pct >= MIN_PCT) || profit >= BIG_PROFIT, 'trust' => trust(sel.size, step, center))
      stat['оценено'] += 1
    end
    save_cache
    [out, stat]
  end

  def mk_info(sel, how, place, typ, t, area)
    ex = sel.sort_by { |a| area && a['a'] ? (a['a'] - area).abs : 0 }.first(4).map { |a| a.slice('p', 'a', 'rep', 's', 'u') }
    { 'n' => sel.size, 'how' => how, 'place' => place, 'ex' => ex,
      'link' => "https://re.kufar.by/l/#{typ == 'let' ? 'snyat' : 'kupit'}/#{{ 'kv' => 'kvartiru', 'dom' => 'dom', 'garage' => 'garazh', 'land' => 'uchastok', 'comm' => 'kommercheskaya' }[t]}" }
  end

  def trust(n, step, center)
    t = n >= 10 && step <= 1 ? 'высокая' : n >= 5 && step <= 3 ? 'средняя' : 'низкая'
    center && t == 'высокая' ? 'средняя' : t
  end
end

