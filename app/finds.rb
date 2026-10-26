#!/usr/bin/env ruby
# encoding: utf-8
require 'json'
require 'shellwords'
require 'erb'
require 'digest'
require_relative 'store'
require_relative 'objects'
require_relative 'vat'
require_relative 'brands'
require_relative 'regions'
require 'time'

module Finds
  module_function

  UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
  API = 'https://api.kufar.by/search-api/v2/search/rendered-paginated?size=60&cat=2010&cnd=1'
  TAX = File.join(Store::DATA, 'kufar_tax.json')
  CACHE = File.join(Store::DATA, 'finds_cache.json')
  MIN_PROFIT = 1000
  MIN_PCT = 20
  BIG_PROFIT = 2500
  RESALE = 0.9
  COSTS = 300
  RESERVE = 0.2
  ENGINE = [[/гибрид/i, 4], [/метан/i, 6], [/пропан|газ/i, 3], [/дизел/i, 2], [/бензин/i, 1]].freeze
  GEAR = [[/механ|МКПП|ручн/i, 2], [/автомат|АКПП|вариатор|робот|DSG|CVT/i, 1]].freeze
  BAD = /авари|ДТП|не\s+на\s+ходу|неисправ|разукомплект|без\s+ключ|без\s+(?:документ|ПТС|техпаспорт|свидетельств)|после\s+пожар|сгоре|затоп|утопл|на\s+запчаст|требует\s+(?:ремонт|восстановл)|поврежд|не\s+заводит|двигатель\s+(?:отсутств|неиспр)|отсутству\S*\s+(?:двигател|кпп|колёс|колес)/i

  def get(url)
    raw = `curl -sS --compressed -m 30 -A #{Shellwords.escape(UA)} #{Shellwords.escape(url)} 2>/dev/null`
    raw.to_s.force_encoding('UTF-8')
  end

  def norm(s)
    s.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.tr('ё', 'е').gsub(/[^a-zа-я0-9]+/, '')
  end

  def tax
    @tax ||= begin
      t = File.exist?(TAX) ? JSON.parse(File.read(TAX)) : {}
      t = {} if Time.now.to_i - t['at'].to_i > 7 * 86_400
      if t['brands'].to_s.empty?
        h = get('https://auto.kufar.by/l/cars')
        b = h.scan(/\{"value":"category_2010\.(mark_[a-z0-9_]+)","labels":\{"ru":"([^"]+)"/).to_h
        t = { 'at' => Time.now.to_i, 'brands' => b, 'models' => {} } if b.size > 50
      end
      t
    end
  end

  def save_tax
    File.write(TAX, JSON.generate(@tax)) if @tax && @tax['brands']
  end

  def brand_code(brand)
    n = norm(brand.to_s.sub(/\s*\(ВАЗ\)/, ''))
    n = { 'лада' => 'ladavaz', 'lada' => 'ladavaz', 'ваз' => 'ladavaz', 'газ' => 'gaz', 'уаз' => 'uaz', 'заз' => 'zaz', 'москвич' => 'moskvich' }[n] || n
    tax['brands'].find { |code, label| norm(label) == n || norm(code.sub('mark_', '')) == n }&.first
  end

  def models(bcode)
    return tax['models'][bcode] if tax['models'][bcode].to_h.any?
    slug = tax['brands'][bcode].to_s.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-|-\z/, '')
    m = {}
    [slug, bcode.sub('mark_', '').tr('_', '-')].uniq.each do |sl|
      h = get("https://auto.kufar.by/l/cars/#{sl}")
      m = h.scan(/\{"value":"category_2010\.#{bcode}\.(model_[a-z0-9_]+)","labels":\{"ru":"([^"]+)"/).to_h
      sleep 1.5
      break if m.any?
    end
    tax['models'][bcode] = m if m.any?
    m
  end

  LAT = { 'а' => 'a', 'в' => 'b', 'е' => 'e', 'к' => 'k', 'м' => 'm', 'н' => 'h', 'о' => 'o', 'р' => 'p', 'с' => 'c', 'т' => 't', 'у' => 'y', 'х' => 'x' }.freeze
  def mnorm(s)
    s.to_s.downcase.tr('ё', 'е').gsub(/[авекмнорстух]/) { |c| LAT[c] }.gsub(/[^a-zа-я0-9]+/, '')
  end

  def model_code(bcode, text)
    words = text.to_s.downcase.tr('ё', 'е').split(/[^a-zа-я0-9-]+/).reject(&:empty?)
    toks = words.map { |w| mnorm(w) }.reject(&:empty?)
    compact = " #{words.map { |w| mnorm(w) }.join(' ')} "
    best = nil
    pick = ->(code, label, score) { best = [code, label, score] if best.nil? || score > best[2] }
    models(bcode).each do |code, label|
      base = label.sub(/\s*\(.*\)\s*\z/, '')
      lw = base.downcase.tr('ё', 'е').split(/[^a-zа-я0-9-]+/).reject(&:empty?).map { |w| mnorm(w) }.reject(&:empty?)
      next if lw.empty?
      if compact.include?(" #{lw.join(' ')} ") || toks.include?(lw.join)
        pick.(code, label, 100 + lw.join.size)
      elsif lw.size == 1 && lw[0] =~ /\A\d{3,4}\z/ && toks.any? { |t| t =~ /\A\d{4,6}\z/ && t.start_with?(lw[0]) }
        pick.(code, label, 50 + lw[0].size)
      elsif base =~ /\A([A-Z]{1,3})-Класс\z/ && (lt = $1.downcase) && toks.any? { |t| t =~ /\A#{lt}\d{2,3}[a-z]*\z/ }
        pick.(code, label, 40 + lt.size)
      elsif base =~ /\A(\d) Серии\z/ && (d = $1) && toks.any? { |t| t =~ /\A#{d}\d{2}[a-z]*\z/ }
        pick.(code, label, 40)
      end
    end
    best && best.first(2)
  end

  def car(l)
    rows = Obj.rows_of(Store.details(l['key']))
    rv = ->(re) { (rows.find { |k, _| k.to_s =~ re } || [])[1].to_s }
    desc = rv.(/\AОписание/)
    text = [rv.(/\AМарка/), rv.(/\AМодель/), l['name']].join(' ')
    brand = l['brand'] || Brands.of(l, rows)
    brand = rv.(/\AМарка\z/) if brand.to_s.empty? || brand == 'Другие'
    all = rows.map { |k, v| "#{k}: #{v}" }.join(' ')
    year = (rv.(/\AГод/)[/(19|20)\d\d/] || l['name'].to_s[/\b(19[89]\d|20[0-2]\d)\b/] ||
            all[/год\S*\s*выпуска\D{0,6}((?:19[89]|20[0-2])\d)/i, 1] || all[/\b((?:19[89]|20[0-2])\d)\s*г\.?\s*в\b/i, 1]).to_i
    eng = "#{rv.(/двигател|топлив/i)} #{l['name']}"
    gear = "#{rv.(/коробк|трансмисс|КПП/i)} #{l['name']}"
    mil = rv.(/пробег/i).gsub(/\D/, '').to_i
    { brand: brand.to_s.strip, text: text, year: year.positive? ? year : nil,
      engine: ENGINE.find { |re, _| eng =~ re }&.last, gear: GEAR.find { |re, _| gear =~ re }&.last,
      mileage: mil.positive? ? mil : nil, bad: "#{l['name']} #{desc}"[BAD] }
  end

  def kufar(params)
    @cache ||= (File.exist?(CACHE) ? JSON.parse(File.read(CACHE)) : {}).reject { |_, v| Time.now.to_i - v['at'].to_i > 3 * 86_400 }
    key = params.sort.map { |k, v| "#{k}=#{v}" }.join('&')
    return @cache[key]['ads'] if @cache[key]
    url = API + params.map { |k, v| "&#{k}=#{ERB::Util.url_encode(v.to_s)}" }.join
    d = (JSON.parse(get(url)) rescue {})
    sleep 1.5
    return nil unless d['ads']
    ads = d['ads'].map do |a|
      pv = ->(k) { (a['ad_parameters'].find { |p| p['p'] == k } || {})['vl'] }
      { 'p' => a['price_byn'].to_i / 100, 'y' => pv.('regdate').to_i, 'km' => pv.('mileage').to_s.gsub(/\D/, '').to_i, 'u' => a['ad_link'], 's' => a['subject'].to_s[0, 80] }
    end.select { |a| a['p'] > 300 }
    @cache[key] = { 'at' => Time.now.to_i, 'ads' => ads }
    ads
  end

  def save_cache
    File.write(CACHE, JSON.generate(@cache)) if @cache
  end

  def market(c, bcode, mcode)
    y = c[:year]
    steps = []
    km = c[:mileage] && c[:mileage] > 5000 ? c[:mileage] : nil
    steps << ['год ±1, двигатель, коробка, пробег ±30%', 1, true, true, true] if c[:engine] && c[:gear] && km
    steps << ['год ±1, пробег ±30%', 1, false, false, true] if km
    steps << ['год ±1, двигатель, коробка', 1, true, true, false] if c[:engine] && c[:gear]
    steps << ['год ±1, двигатель', 1, true, false, false] if c[:engine]
    steps << ['год ±1', 1, false, false, false]
    steps << ['год ±2', 2, false, false, false]
    steps.each do |name, dy, e, g, mlg|
      p = { 'cbnd2' => "category_2010.#{bcode}", 'cmdl2' => "category_2010.#{bcode}.#{mcode}", 'rgd' => "r:#{y - dy},#{y + dy}" }
      p['cre'] = "v.or:#{c[:engine]}" if e
      p['crg'] = "v.or:#{c[:gear]}" if g
      p['mlg'] = "r:#{(km * 0.7).round},#{(km * 1.3).round}" if mlg
      ads = kufar(p) or next
      next if ads.size < 2
      ps = ads.map { |a| a['p'] }.sort
      return { 'median' => ps[ps.size / 2], 'low' => ps[(ps.size * 0.25).floor], 'high' => ps[(ps.size * 0.75).floor],
               'n' => ads.size, 'how' => name, 'ex' => ads.sort_by { |a| a['p'] }.values_at(0, ads.size / 2, -1).uniq,
               'link' => 'https://auto.kufar.by/l/cars?' + p.map { |k, v| "#{k}=#{ERB::Util.url_encode(v)}" }.join('&') }
    end
    nil
  end

  def markups(lots)
    now = Time.now.to_i
    r = Hash.new { |h, k| h[k] = [] }
    lots.each do |l|
      x = l['result']
      next unless l['section'] == 'avto' && x.is_a?(Hash) && %w[sold single].include?(x['st']) && x['at'].to_i > now - 365 * 86_400
      st = (x['start'] || l['price']).to_f
      next unless st.positive? && x['price'].to_f.positive?
      r[l['platform']] << x['price'].to_f / st
      r['_'] << x['price'].to_f / st
    end
    r.transform_values { |v| v.sort! && { 'n' => v.size, 'med' => v[v.size / 2].round(2), 'q75' => v[(v.size * 0.75).floor].round(2) } }
  end

  SCALE = { 'torgi' => [[50_000, 5], [250_000, 4], [500_000, 3], [1e6, 2], [1e7, 1], [Float::INFINITY, 0.2]],
            'lotsale' => [[7500, 8], [50_000, 5], [250_000, 4], [500_000, 3], [1e6, 2], [Float::INFINITY, 1]] }.freeze

  def costs(l, buy)
    t = l['terms'] || {}
    pct = t['fee_pct'].to_f
    pct = SCALE[t['fee_scale']].find { |to, _| buy <= to }[1] if pct.zero? && SCALE[t['fee_scale']]
    fee = (t['fee_base'] == 'start' ? l['price'].to_f : buy) * pct / 100
    fee = [fee, t['fee_min'].to_f].max if pct.positive?
    vat = Vat.kind(t, Store.details(l['key']).flat_map { |s| (s['rows'] || []).map { |r| r.join(' ') } }.join(' ')) == 'add' ? buy * 0.2 : 0
    { 'fee_pct' => pct, 'fee' => fee.round, 'fee_abs' => t['fee_abs'].to_f.round, 'vat' => vat.round }
  end

  def history(lots)
    now = Time.now.to_i
    h = Hash.new { |x, k| x[k] = [] }
    lots.each do |l|
      r = l['result']
      next unless l['section'] == 'avto' && r.is_a?(Hash) && %w[sold single].include?(r['st']) && r['price'].to_f.positive? && r['at'].to_i > now - 548 * 86_400
      c = car(l)
      next unless c[:year] && (b = brand_code(c[:brand]))
      m, = model_code(b, c[:text])
      h[[b, m]] << { 'y' => c[:year], 'p' => r['price'].round, 'pl' => l['platform'], 'at' => r['at'].to_i } if m
    end
    h
  end

  def run(lots)
    mk = markups(lots)
    hist = history(lots)
    now = Time.now.to_i
    out = []
    stat = Hash.new(0)
    lots.select { |l| l['status'] == 'active' && l['section'] == 'avto' && l['req_to'].to_i > now && l['price'].to_f.positive? }.each do |l|
      stat['легковых'] += 1
      (stat['доля в праве'] += 1; next) if l['name'].to_s =~ %r{\bдол[яиюей]\b|\b\d+/\d+\b}i
      c = car(l)
      (stat['нет года'] += 1; next) unless c[:year]
      bcode = brand_code(c[:brand]) or (stat['марка не найдена на Kufar'] += 1; next)
      mcode, mlabel = model_code(bcode, c[:text])
      (stat['модель не найдена на Kufar'] += 1; next) unless mcode
      m = market(c, bcode, mcode) or (stat['меньше 2 объявлений'] += 1; next)
      stat['с оценкой'] += 1
      k = mk[l['platform']] && mk[l['platform']]['n'] >= 10 ? mk[l['platform']] : mk['_']
      sim = (hist[[bcode, mcode]] || []).select { |h| (h['y'] - c[:year]).abs <= 2 }
      if sim.size >= 2
        ps = sim.map { |h| h['p'] }.sort
        auc = { 'n' => sim.size, 'med' => ps[ps.size / 2], 'ex' => sim.sort_by { |h| -h['at'] }.first(3) }
        buy = [l['price'].to_f * (l['platform'] == 'belauction.by' ? 1 : [k['q75'], 1.0].max), auc['med']].max.round
        how = "продажи этой модели на торгах (#{sim.size})"
      elsif l['platform'] == 'belauction.by'
        stat['belauction без истории продаж модели'] += 1
        next
      else
        auc = nil
        buy = (l['price'].to_f * [k['q75'], 1.0].max).round
        how = "наценка площадки ×#{k['q75']}"
      end
      lid = l['id'] || (l['key'].start_with?('ipm-') ? "ipm-#{Digest::MD5.hexdigest(l['key'])[0, 8]}" : Store.fname(l['key']))
      out << { 'key' => l['key'], 'id' => lid, 'name' => l['name'], 'platform' => l['platform'], 'url' => l['url'], 'region' => l['region'],
               'city' => place_of(l['location'], l['region']), 'location' => l['location'],
               'req_to' => l['req_to'], 'start' => l['price'].round, 'markup' => k, 'buy' => buy, 'buy_how' => how, 'auction' => auc,
               'car' => { 'brand' => c[:brand], 'model' => mlabel, 'year' => c[:year], 'engine' => c[:engine], 'gear' => c[:gear], 'km' => c[:mileage] },
               'market' => m, 'bad' => c[:bad], '_l' => l }
    end
    sh = out.select { |x| x['auction'] && x['auction']['n'] >= 3 }.group_by { |x| x['platform'] }
            .transform_values { |v| v.map { |x| x['auction']['med'].to_f / x['market']['median'] }.sort }
    all = sh.values.flatten.sort
    share = ->(p) { v = sh[p] && sh[p].size >= 5 ? sh[p] : all; v.empty? ? 0.49 : v[v.size / 2] }
    out.each do |x|
      l = x.delete('_l')
      unless x['auction']
        s = share.(x['platform'])
        if x['market']['median'] * s > x['buy']
          x['buy'] = (x['market']['median'] * s).round
          x['buy_how'] = "обычная цена на торгах ~#{(s * 100).round}% рынка (истории модели нет)"
        end
      end
      cs = costs(l, x['buy'])
      x['costs'] = cs
      x['total'] = x['buy'] + cs['fee'] + cs['fee_abs'] + cs['vat']
      x['reserve'] = (x['market']['median'] * RESERVE).round
      x['sell'] = (x['market']['median'] * RESALE - COSTS).round
      x['profit'] = x['sell'] - x['reserve'] - x['total']
      x['pct'] = (x['profit'] * 100.0 / x['total']).round
      x['find'] = (x['profit'] >= MIN_PROFIT && x['pct'] >= MIN_PCT) || x['profit'] >= BIG_PROFIT
      sp = (x['market']['high'] - x['market']['low']).to_f / x['market']['median']
      x['trust'] = x['market']['n'] >= 10 && sp <= 0.5 ? 'высокая' : x['market']['n'] < 5 || sp > 1.0 ? 'низкая' : 'средняя'
    end
    save_tax
    save_cache
    [out.sort_by { |x| -x['profit'] }, stat]
  end

  def sync(res)
    now = Time.now
    rows = res.select { |x| x['find'] }.map do |x|
      { 'lot' => x['key'], 'data' => x, 'profit' => x['profit'], 'total' => x['total'], 'region' => x['region'], 'city' => x['city'],
        'req_to' => Time.at(x['req_to'].to_i).utc.iso8601, 'active' => true, 'updated_at' => now.utc.iso8601 }
    end
    Sb.upsert('finds', rows, 'lot') if rows.any?
    keep = rows.map { |r| r['lot'] }
    old = Sb.get('finds?active=eq.true&select=lot').map { |r| r['lot'] } - keep
    old.each_slice(100) { |sl| Sb.patch('finds', "lot=in.(#{sl.map { |k| %("#{k}") }.join(',')})", { 'active' => false, 'updated_at' => now.utc.iso8601 }) }
    [rows.size, old.size]
  end

  def deliver
    now = Time.now
    today = now.strftime('%Y-%m-%d')
    users = Sb.get('users?select=id,features').select { |u| (u['features'] || {})['finds'] }
    cands = Sb.get('finds?active=eq.true&select=lot,req_to')
    cands.select! { |c| Time.parse(c['req_to'].to_s) > now rescue true }
    users.map do |u|
      seen = Sb.get("user_finds?user_id=eq.#{u['id']}&select=lot").map { |h| h['lot'] }
      pick = cands.reject { |c| seen.include?(c['lot']) }
      Sb.upsert('user_finds', pick.map { |c| { 'user_id' => u['id'], 'lot' => c['lot'], 'status' => 'new', 'delivered_on' => today } }, 'user_id,lot') if pick.any?
      "#{u['id']}: +#{pick.size}"
    end.join(', ')
  end
end

if $PROGRAM_NAME == __FILE__
  lots = JSON.parse(File.read(ARGV.find { |a| !a.start_with?('--') } || File.join(Store::DATA, 'lots.json'), encoding: 'utf-8'))
  lots = lots.values if lots.is_a?(Hash)
  res, stat = Finds.run(lots)
  require_relative 'finds_realty'
  rr, rst = FindsRealty.run(lots, Finds)
  res += rr
  out = ARGV.reject { |a| a.start_with?('--') }[1] || 'tmp/finds.json'
  File.write(out, JSON.pretty_generate(res))
  puts stat.map { |k, v| "#{k}: #{v}" }.join(', ')
  puts rst.map { |k, v| "#{k}: #{v}" }.join(', ')
  puts "находок: #{res.count { |x| x['find'] }} (недвижимость #{rr.count { |x| x['find'] }})"
  if ARGV.include?('--db')
    require_relative 'sb'
    abort 'нет доступа к базе (SB_URL, SB_KEY, SB_TOKEN)' unless Sb.on?
    n, off = Finds.sync(res)
    puts "в базе: активных #{n}, снято #{off}"
    puts "раскладка: #{Finds.deliver}"
  end
end
