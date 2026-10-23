#!/usr/bin/env ruby
# encoding: utf-8
require 'json'
require 'base64'
require 'fileutils'
require 'digest'
require 'uri'
require 'zlib'
require_relative 'store'
require_relative 'regions'
require_relative 'sb'
require_relative 'similar'
require_relative 'zones'
require_relative 'bav'
require_relative 'cats'
require_relative 'area'
require_relative 'statsfile'
require_relative 'vat'
require_relative 'chance'
require_relative 'brands'
require_relative 'mgcn'
require_relative 'pages'
require_relative 'indexnow'
require 'cgi'

OUT  = ENV['OUT'] || File.join(Store::ROOT, '_site')
TMP  = File.join(Store::ROOT, 'tmp')
PACKS = 1000
ARCH_NEW = 45
KEEP = %w[dn yr id art name price req_to torg url location region city debtor area_num platform section off
          photo pk market prices status closed why first_seen alt pin result phx land sub chance brand u].freeze
SECS = %w[nedvizhimost avto gruz spec oborud arenda].freeze

FIO = /[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\s+(?:[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:вич|вна|ична|ич)|[А-ЯЁ]\.\s?[А-ЯЁ]\.)/
PRIVATE = { /Должник|Собственник/ => 'Физическое лицо',
            /Контактное лицо|Мобильный|Ознакомление и осмотр/ => 'Указан на площадке' }.freeze

def mask(secs)
  secs.each do |s|
    s['rows'].each do |row|
      rule = PRIVATE.find { |re, _| row[0] =~ re } or next
      row[1] = rule[1] if row[1].to_s =~ FIO
    end
  end
end

def id_of(key)
  key.start_with?('ipm-') ? "ipm-#{Digest::MD5.hexdigest(key)[0, 8]}" : Store.fname(key)
end

def words(s)
  s.to_s.downcase.tr('ё', 'е').scan(/[a-zа-я0-9]{3,}/).uniq
end

ADM = if Sb.on?
        begin
          { 'cfg' => Sb.settings, 'ov' => Sb.all('overrides').map { |o| [o['key'], o] }.to_h,
            'rules' => Sb.all('dup_rules'), 'photos' => Sb.all('lot_photos', 'key,updated_at'),
            'news' => Sb.get('news?select=*&published=is.true&order=date.desc,updated_at.desc&limit=500'),
            'media' => Sb.get('site_media?select=id,data&limit=500') }
        rescue StandardError => e
          abort "база админки не ответила — сайт не пересобираю, остаётся прежняя версия: #{e.message}"
        end
      else
        { 'cfg' => {}, 'ov' => {}, 'rules' => [], 'photos' => [], 'sales' => [] }
      end
ST_PTR = Sb.on? ? (Sb.get('stats_file?select=name,key&order=at.desc&limit=1').first rescue nil) : nil
ST_PREV = StatsFile.previous(ST_PTR)
sales_full_at = Time.now.to_i
if Sb.on?
  begin
    copy = ST_PREV && ST_PREV['data']
    n = copy && Time.now.to_i - copy['full_at'].to_i < StatsFile::FULL_EVERY ? (Sb.count('sales') rescue -1) : -1
    if copy && n == copy['sales']['r'].size
      ADM['sales'] = StatsFile.rows(copy['sales'])
      sales_full_at = copy['full_at'].to_i
      puts "итоги торгов: копия из файла аналитики (#{n}), из базы не качаем"
    else
      puts "итоги торгов: из базы целиком#{copy ? " (в базе #{n}, в копии #{copy['sales']['r'].size} или копии больше недели)" : ''}"
      ADM['sales'] = Sb.all('sales')
    end
  rescue StandardError => e
    abort "база админки не ответила (итоги торгов) — сайт не пересобираю, остаётся прежняя версия: #{e.message}"
  end
end
CFG = ADM['cfg']
OV = ADM['ov']
MOD_SINCE = CFG['mod_since'].to_i

now = Time.now.to_i
lots = Store.load
nplat = lots.map { |l| l['platform'] }.uniq.size
web = ->(u) { u.is_a?(String) && u =~ %r{\Ahttps?://}i ? u : nil }
lots.each do |l|
  l['url'] = web.(l['url'])
  l['url'] = web.(l['tk']) || l['url'] if l['platform'] == 'konfiskat.by' && l['tk'] && (l['section'] != 'nedvizhimost' || l['tk_chk'])
  l['phx'] = web.(l['phx']) if l['phx']
  l['pics'] = l['pics'].select { |u| web.(u) } if l['pics'].is_a?(Array)
  l['market'] = l['market'].merge('link' => web.(l['market']['link'])) if l['market'].is_a?(Hash) && l['market']['link']
  if l['status'] == 'active' && l['req_to'].to_i <= now
    l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
  end
  if l['platform'] == 'konfiskat.by' && (a = Obj.kf_name_addr(l['name']))
    l['location'] = a
  end
  l['location'] = 'г. Минск' if l['platform'] == 'konfiskat.by' && l['location'].to_s.strip.empty?
  l['region'] = region_of(l['location'])
  if %w[nedvizhimost arenda].include?(l['section']) && !l['area_num'].to_f.positive?
    land = l['sub_ru'].to_s =~ /участ/i || l['name'].to_s =~ /\A\s*земельн\S*\s+участ/i
    txt = ([l['name']] + Store.details(l['key']).flat_map { |s| (s['rows'] || []).map { |r| r.join(': ') } }).join(' ')
    a = Area.of(txt, land: !!land)
    l['area_num'] = a if a
  end
  l['debtor'] = 'Физическое лицо' if ENV['MASK'] && l['debtor'].to_s =~ FIO
  l['id'] = id_of(l['key'])
  l['photo'] = File.exist?(Store.ph_path(l['key'])) ? l['id'] : nil
  l['land'] = 1 if l['section'] == 'nedvizhimost' && (l['sub_ru'] == 'Земельные участки' || l['name'].to_s =~ /\A\s*земельн\S*\s+участ/i)
  l.delete('prices') unless (l['prices'] || []).size > 1
  if (m = l['market'])
    r = m['median'].to_f.positive? ? l['price'].to_f / m['median'] : 0
    l.delete('market') unless r >= 0.30 && r <= 3.0 && m['n'].to_i >= 3
  end
end
Chance.apply(lots, now)

MIRROR = %w[key id art platform section name price req_to torg location region url area_num debtor].freeze
orig = lots.map { |l| [l['key'], MIRROR.map { |k| [k, l[k]] }.to_h] }.to_h
raw = lots.map { |l| [l['key'], l.slice('terms', 'pics')] }.to_h

descr = {}
ph_src = {}
lots.each do |l|
  o = OV[l['key']] or next
  f = o['fields'] || {}
  %w[name location].each { |k| l[k] = f[k].to_s.strip unless f[k].to_s.strip.empty? }
  l['region'] = region_of(l['location']) unless f['location'].to_s.strip.empty?
  l['section'] = f['section'] if SECS.include?(f['section'])
  l['price'] = f['price'].to_f if f['price'].to_f.positive?
  l['area_num'] = f['area_num'].to_f if f['area_num'].to_f.positive?
  l['debtor'] = f['debtor'].to_s.strip unless f['debtor'].to_s.strip.empty?
  if (tm = f['terms']).is_a?(Hash) && tm.any?
    t = (l['terms'] || {}).dup
    t = t.reject { |k, _| %w[step_abs step_pct step_base first_pct step_min_pct].include?(k) } if tm['step_abs'] || tm['step_pct']
    t = t.reject { |k, _| %w[fee_scale fee_base fee_min].include?(k) } if tm['fee_pct']
    t = t.reject { |k, _| %w[fee_later fee_upto fee_scale].include?(k) } if tm['fee_abs']
    t.delete('vat_add') if tm.key?('vat')
    l['terms'] = t.merge(tm).merge('man' => 1)
  end
  hp = Array(f['hide_pics'])
  if hp.any?
    first = (l['pics'] || [])[0]
    l['pics'] -= hp if l['pics'].is_a?(Array)
    l['photo'] = nil if hp.include?('main') || (first && hp.include?(first))
  end
  %w[req_to torg].each { |k| l[k] = f[k].to_i if f[k].to_i.positive? }
  descr[l['key']] = f['descr'].to_s.strip unless f['descr'].to_s.strip.empty?
  if (m = f['market'])
    if m['off']
      l.delete('market')
    elsif m['median'].to_f.positive?
      l['market'] = { 'median' => m['median'].to_f, 'manual' => true, 'note' => m['note'].to_s, 'source' => 'оценка МониТорга' }
    end
  end
  if f['req_to'].to_i.positive?
    if l['req_to'] > now && l['status'] == 'archive' && l['why'] == 'deadline'
      l['status'] = 'active'
      %w[closed why].each { |k| l.delete(k) }
    elsif l['req_to'] <= now && l['status'] == 'active'
      l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
    end
  end
  if f['removed'].to_i.positive? && l['status'] == 'active'
    l.merge!('status' => 'archive', 'closed' => f['removed'].to_i, 'why' => 'removed')
  end
  if (r = f['result']).is_a?(Hash) && %w[sold single failed cancelled].include?(r['st']) && l['status'] == 'archive'
    l['result'] = { 'st' => r['st'], 'start' => l['price'], 'price' => r['price'].to_f.positive? ? r['price'].to_f : nil,
                    'at' => (l['torg'] || l['req_to']).to_i, 'man' => 1 }.compact
  end
  l['pin'] = 1 if o['pinned'] && l['status'] == 'active'
end

lots.each do |l|
  next unless %w[avto gruz spec].include?(l['section']) && l['name'].to_s =~ /\A\s*(?:[её]мкость|бочка)/i && l['name'] !~ /МЖТ/i
  l['section'] = 'oborud' unless ((OV[l['key']] || {})['fields'] || {})['section']
end
lots.each { |l| l['sub'] = Cats.of(l, ->(k) { Store.details(k) }) }
auto_sub = {}
lots.each do |l|
  f = (OV[l['key']] || {})['fields'] || {}
  next unless f['sub'] || f['section']
  auto_sub[l['key']] = Cats.of(l.merge('section' => orig[l['key']]['section']), ->(k) { Store.details(k) })
  l['sub'] = f['sub'] if Cats.valid?(f['sub'])
end
BRAND_SUBS = %w[transport/legkovye transport/gruzovye transport/avtobusy].freeze
lots.each { |l| l['brand'] = Brands.of(l, Store.details(l['key']).flat_map { |x| x['rows'] || [] }) if l['status'] == 'active' && BRAND_SUBS.include?(l['sub']) }
lots.each { |l| l['city'] = place_of(l['location'], l['region']) }

FileUtils.mkdir_p(File.join(TMP, 'ph'))
by_key = lots.map { |l| [l['key'], l] }.to_h
ADM['photos'].each do |p|
  l = by_key[p['key']] or next
  row = Sb.get("lot_photos?key=eq.#{URI.encode_www_form_component(p['key'])}&select=data").first or next
  raw = File.join(TMP, 'ph', "#{Digest::MD5.hexdigest(p['key'])}.src")
  dst = File.join(TMP, 'ph', "#{Digest::MD5.hexdigest(p['key'])}.jpg")
  File.binwrite(raw, Base64.decode64(row['data'].to_s.sub(/\Adata:[^,]*,/, '')))
  next warn("фото из админки не обработалось: #{p['key']}") unless Store.shrink(raw, dst)
  ph_src[l['key']] = dst
  l['photo'] = l['id']
end

plat_off = (CFG['platforms'] || {}).select { |_, v| v == false }.keys
sec_off = (CFG['sections'] || {}).select { |_, v| v == false }.keys
hidden_why = {}
lots.each do |l|
  hw = if plat_off.include?(l['platform']) then 'plat_off'
       elsif sec_off.include?(l['section']) then 'sec_off'
       elsif (OV[l['key']] || {})['mod'] == 'hidden' then 'hidden'
       end
  hidden_why[l['key']] = hw if hw
end

active = lots.select { |l| l['status'] == 'active' && !hidden_why[l['key']] }.sort_by { |l| l['req_to'].to_i }
arch = lots.select { |l| l['status'] == 'archive' && !hidden_why[l['key']] }.sort_by { |l| -l['closed'].to_i }

BARE_NAME = /\A(?:квартира|жилой дом|дом|жилое помещение|гараж|машино-?место|магазин|здание магазина|здание|помещение|изолированное помещение|капитальное строение|комплекс зданий|склад|павильон(?: торговый)?|земельный участок|баня|кафе|офис|столовая)\z/i
(active + arch).each do |l|
  n = l['name'].to_s.strip
  n = n.sub(/[\s,;:–—-]*(?:№|N)?[\s,;:–—-]*\z/, '') while n =~ /[,;:–—-]\s*\z|(?:\s|,)(?:№|N)\s*\z/
  if n.sub(/[.\s]+\z/, '') =~ BARE_NAME
    n = n.sub(/[.\s]+\z/, '')
    a = l['area_num'].to_f
    tn = l['region'] == 'г. Минск' ? 'Минск' : (m = l['location'].to_s.match(Obj::PLACE)) ? m[2] : nil
    n = [n, (a.positive? ? "#{a.round(1).to_s.sub(/\.0\z/, '').tr('.', ',')} м²" : nil), tn].compact.join(', ')
  end
  l['name'] = n unless n.empty?
end
active.group_by { |l| l['name'].to_s.downcase }.each_value { |v| v.each { |l| l['dn'] = 1 } if v.size > 1 }
(active + arch).each do |l|
  next unless %w[avto gruz spec].include?(l['section'])
  y = Obj.year_of(l['status'] == 'active' ? Obj.rows_of(Store.details(l['key'])) : [], l['name'])
  l['yr'] = y if y && y.between?(1950, Time.now.year + 1)
end

sig = lambda do |l|
  l['name'].to_s.downcase.tr('ё', 'е').gsub(/[^a-zа-я0-9]/, '') + '|' + l['price'].to_f.round.to_s
end
when_ = ->(l) { l['torg'] || l['req_to'].to_i + 86_400 }
split_pairs = {}
manual = {}
sigs = active.map { |l| [l['key'], sig.(l)] }.to_h
ADM['rules'].each do |r|
  if r['kind'] == 'split'
    split_pairs[[r['a'], r['b']].sort] = true
    sigs[r['b']] = "k|#{r['b']}" if sigs[r['b']] && sigs[r['a']] == sigs[r['b']]
  end
end
ADM['rules'].each do |r|
  next unless r['kind'] == 'merge' && sigs[r['a']] && sigs[r['b']]
  old = sigs[r['b']]
  sigs.each_key { |k| sigs[k] = sigs[r['a']] if sigs[k] == old }
  manual[sigs[r['a']]] = true
end
dup_of = {}
active.group_by { |l| sigs[l['key']] }.each do |s, g|
  next if g.size < 2
  next if !manual[s] && g.map { |l| l['platform'] }.uniq.size < 2
  main = g.min_by { |l| [when_.(l), l['req_to'].to_i, l['price'].to_f.positive? ? 0 : 1] }
  others = if manual[s]
             g - [main]
           else
             g.reject { |l| l['platform'] == main['platform'] }.group_by { |l| l['platform'] }.map { |_, v| v.min_by(&when_) }
           end
  main['alt'] = ([main] + others).sort_by(&when_).map { |l| { 'platform' => l['platform'], 'url' => l['url'], 'req_to' => l['req_to'], 'torg' => l['torg'] } }
  others.each { |l| dup_of[l['key']] = main['key'] }
end
active.reject! { |l| dup_of[l['key']] }
puts "склеено дублей: #{dup_of.size}" unless dup_of.empty?

dup_with = {}
active.select { |l| l['price'].to_f.positive? }.group_by { |l| l['price'].to_f.round }.each_value do |g|
  next if g.size < 2 || g.size > 40
  g.combination(2) do |a, b|
    next if a['platform'] == b['platform'] || split_pairs[[a['key'], b['key']].sort]
    wa = words(a['name'])
    wb = words(b['name'])
    next if wa.empty? || wb.empty? || (wa & wb).size.to_f / (wa | wb).size < 0.5
    dup_with[a['key']] ||= b['key']
    dup_with[b['key']] ||= a['key']
  end
end
BAD_NAME = /\A(лот\s*№?\s*\d+|имущество|недвижимое имущество|транспортное средство|автомобиль|легковой автомобиль|грузовой автомобиль|объект|здание|сооружение|оборудование|товары?|изолированное помещение|капитальное строение)\.?\z/i
SOFT = %w[no_area bad_dates].freeze
same = ->(v) { v.is_a?(Numeric) ? v.to_f.round(2) : v.to_s.strip }
reasons = {}
active.each do |l|
  r = []
  o = OV[l['key']] || {}
  fresh = MOD_SINCE.positive? && l['first_seen'].to_i > MOD_SINCE
  r << 'no_photo' unless l['photo'] || l['phx'] || l['platform'] == 'mgcn.by'
  r << 'no_price' unless l['price'].to_f.positive?
  r << 'no_city' if l['location'].to_s.strip.empty? || l['region'].to_s.empty?
  if l['platform'] == 'konfiskat.by' && Store.details(l['key']).any? { |s| s['rows'].any? { |_, v| v.to_s.include?('по правилу организатора') } }
    r << 'rule_deadline'
  end
  r << 'dup_maybe' if dup_with[l['key']]
  r << 'bad_dates' if l['torg'].to_i.positive? && l['torg'].to_i < l['req_to'].to_i - 60
  r << 'bad_name' if l['name'].to_s.strip.size < 4 || l['name'].to_s.strip =~ BAD_NAME
  r << 'no_area' if fresh && l['section'] == 'nedvizhimost' && !l['area_num'].to_f.positive? && l['platform'] != 'torgi.gov.by'
  if (b = o['base']).is_a?(Hash) && b.any? { |k, v| orig[l['key']].key?(k) && same.(orig[l['key']][k]) != same.(v) }
    r << 'plat_changed'
  end
  reasons[l['key']] = r
end
queued = 0
active.reject! do |l|
  o = OV[l['key']] || {}
  fresh = MOD_SINCE.positive? && l['first_seen'].to_i > MOD_SINCE
  hold = o['mod'] == 'review' || (fresh && (reasons[l['key']] - SOFT).any? && o['mod'] != 'approved')
  next false unless hold
  hidden_why[l['key']] = 'mod'
  dup_of.each { |k, m| hidden_why[k] = 'dup' if m == l['key'] }
  queued += 1
  true
end
dup_of.each_key { |k| hidden_why[k] ||= 'dup' }
puts "ждут проверки: #{queued}" if queued.positive?

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p([File.join(OUT, 'ph'), File.join(OUT, 'det'), File.join(OUT, 'admin')])

shown = (active + arch).map { |l| [l['key'], l['id']] }.to_h
sim = Similar.run(lots, shown, ADM['sales'], ->(k) { Store.details(k) })
puts "похожие торги: у #{sim.count { |_, v| v['c'] }} лотов, история объекта: у #{sim.count { |_, v| v['h'] }}"

Pages.prepare(active: active, arch: arch, details: ->(k) { Store.details(k) }, now: now)
order = active.group_by { |l| l['section'] }.values.flatten + arch
packs = 0
vat_stat = Hash.new(0)
order.group_by { |l| Zlib.crc32(l['id']) % PACKS }.each do |pk, chunk|
  det = {}
  chunk.each do |l|
    l['pk'] = pk
    secs = Store.details(l['key'])
    if (d = descr[l['key']])
      row = secs.flat_map { |s| s['rows'] }.find { |k, _| k.to_s =~ /\AОписание/i }
      if row
        row[1] = d
      else
        secs.unshift('h' => 'Сведения о лоте', 'rows' => [['Описание', d]])
      end
    end
    t = l['terms'] || {}
    vk = Vat.kind(t, secs.flat_map { |sx| (sx['rows'] || []).map { |r| r.join(' ') } }.join(' '))
    vat_stat[vk || 'нет'] += 1 if l['status'] == 'active'
    x = { 's' => ENV['MASK'] ? mask(secs) : secs, 't' => t.merge('vk' => vk) }
    x.merge!((sim[l['key']] || {}).slice('c', 'h'))
    x['p'] = l['pics'] if (l['pics'] || []).size.positive?
    if l['status'] == 'active' && l['geo'].is_a?(Array)
      x['g'] = l['geo'] + [l['platform'] == 'konfiskat.by' ? Obj.kf_addr(l['name'], Obj.rows_of(secs)) : l['location']]
    end
    if l['rent']
      rt = l['rent']
      rt = Mg.rent(rt['raw'], nil, rt['S']) || rt if rt['k'] == 'ks' && rt['raw'] && l['platform'] == 'mgcn.by'
      x['r'] = rt.merge(rt['k'] == 'ks' ? { 'z' => Zones.at(l['geo']) } : {})
    end
    x['l'] = KEEP.each_with_object({}) { |k, h| h[k] = l[k] unless l[k].nil? } if l['status'] == 'archive'
    det[l['id']] = x
    FileUtils.cp(ph_src[l['key']] || Store.ph_path(l['key']), File.join(OUT, 'ph', "#{l['id']}.jpg")) if l['photo']
  end
  File.write(File.join(OUT, 'det', "p#{pk}.js"), "__det(#{pk},#{JSON.generate(det)});")
  packs += 1
end
puts "НДС у активных лотов: #{vat_stat.sort_by { |_, n| -n }.map { |k, n| "#{k} #{n}" }.join(', ')}"

pub = { 'texts' => CFG['texts'] || {}, 'calc' => CFG['calc'] || {}, 'sec_off' => sec_off,
        'bav' => Bav.load.slice('v', 'from', 'src', 'url'),
        'cats' => Cats.tree }
pub['sb'] = { 'url' => ENV['SB_URL'], 'key' => ENV['SB_KEY'] } if Sb.on?
def nbrb_usd
  u = URI('https://api.nbrb.by/exrates/rates/USD?parammode=2')
  2.times do
    begin
      j = JSON.parse(Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |h| h.get(u.request_uri).body })
      r = j['Cur_OfficialRate'].to_f / (j['Cur_Scale'] || 1).to_f
      return { 'rate' => r.round(4), 'date' => j['Date'].to_s[0, 10] } if r > 1 && r < 100
    rescue StandardError => e
      warn "курс НБРБ: #{e.class}"
    end
    sleep 3
  end
  nil
end
pub['usd'] = nbrb_usd
if CFG['home'].is_a?(Hash)
  media = {}
  if ADM['media']
    FileUtils.mkdir_p(File.join(OUT, 'media'))
    ADM['media'].each do |m|
      next unless m['id'].to_s =~ /\A[\w-]{1,40}\z/
      ext = m['data'].to_s.start_with?('data:image/png') ? 'png' : 'jpg'
      file = "media/#{m['id']}-#{Digest::MD5.hexdigest(m['data'].to_s)[0, 8]}.#{ext}"
      File.binwrite(File.join(OUT, file), Base64.decode64(m['data'].to_s.sub(/\Adata:[^,]*,/, '')))
      media[m['id']] = file
    end
  end
  link = ->(u) { u.to_s.strip =~ %r{\A(https?://|#/)}i ? u.to_s.strip : nil }
  home = JSON.parse(JSON.generate(CFG['home']))
  fix = lambda do |o|
    case o
    when Array then o.each { |x| fix.(x) }
    when Hash
      o.each_key do |k|
        if %w[img logo].include?(k) then o[k] = media[o[k]]
        elsif k == 'imgs' && o[k].is_a?(Hash) then o[k] = o[k].transform_values { |v| media[v] }.compact
        elsif k == 'imgs' && o[k].is_a?(Array) then o[k] = o[k].map { |v| media[v] }
        elsif %w[url btn_url].include?(k) then o[k] = link.(o[k])
        else fix.(o[k])
        end
      end
    end
  end
  fix.(home)
  pub['home'] = home
end
if ADM['news']
  FileUtils.mkdir_p(File.join(OUT, 'media', 'news'))
  pub['news'] = ADM['news'].map do |n|
    img = n['photo'].to_s
    if img.start_with?('data:')
      file = "media/news/#{Digest::MD5.hexdigest(n['slug'].to_s)[0, 10]}-#{Digest::MD5.hexdigest(img)[0, 8]}.jpg"
      File.binwrite(File.join(OUT, file), Base64.decode64(img.sub(/\Adata:[^,]*,/, '')))
      img = file
    end
    { 'slug' => n['slug'], 'date' => n['date'], 'title' => n['title'], 'lead' => n['lead'], 'body' => n['body'],
      'img' => (img.empty? ? nil : img), 'src' => n['src'], 'srcName' => n['src_name'],
      'cta' => (n['cta_text'].to_s.strip.empty? || n['cta_url'].to_s.strip.empty? ? nil : [n['cta_text'], n['cta_url']]) }.compact
  end
end

arch_cut = now - ARCH_NEW * 86_400
arch1, arch2 = arch.partition { |l| l['closed'].to_i >= arch_cut }
archn = arch.group_by { |l| l['section'] }.map { |k, v| [k, v.size] }.to_h.merge('_' => arch.size, 'cut' => arch_cut)
archn['tree'] = arch.each_with_object(Hash.new(0)) { |l, h| next unless l['sub']; h[l['sub']] += 1; h[l['sub'].split('/').first] += 1 }
slim = ->(l) { KEEP.each_with_object({}) { |k, h| h[k] = l[k] unless l[k].nil? }.tap { |h| h['np'] = l['pics'].size if (l['pics'] || []).size > 1 } }
tpl = File.read(File.join(__dir__, 'site.tpl.html'), encoding: 'UTF-8')
SEO_DEF = { 'seo_title' => 'МониТорг - торги по имуществу должников Беларуси', 'seo_brand' => 'МониТорг',
            'seo_desc' => 'Все торги по имуществу Беларуси в одном каталоге: недвижимость, авто, спецтехника, оборудование и аренда ' \
                          'с 18 площадок. Фильтры, история цен, итоги торгов.',
            'seo_short' => 'Агрегатор торгов по имуществу со всех площадок Беларуси' }.freeze
seo = SEO_DEF.map { |k, v| t = ((CFG['texts'] || {})[k]).to_s.strip; [k, (t.empty? ? v : t).gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;')] }.to_h
tpl = tpl.gsub('__TITLE__', seo['seo_title']).gsub('__DESC__', seo['seo_desc']).gsub('__SHORT__', seo['seo_short']).gsub('__BRAND__', seo['seo_brand'])
tpl_head = tpl[0...tpl.index('<script>')]
i_js = tpl.index("<script>\nconst DATA = window.MT_DATA;") or abort 'шаблон: нет начала приложения'
body_tpl = tpl[(tpl.index('</style>') + 8)...i_js]
FileUtils.mkdir_p(File.join(OUT, 'assets'))
File.write(File.join(OUT, 'assets', 'site.css'), tpl[%r{<style>(.*?)</style>}m, 1] + Pages::CSS)
File.write(File.join(OUT, 'assets', 'theme.js'), tpl[%r{<script>\s*(/\* Общий стиль.*?)</script>}m, 1]
  .sub('__THEME__') { JSON.generate((pub['home'] || {})['theme'] || {}) })
File.write(File.join(OUT, 'assets', 'app.js'), tpl[(i_js + 8)...tpl.rindex('</script>')])
File.write(File.join(OUT, 'assets', 'data.js'),
           "window.MT_DATA=#{JSON.generate(active.map(&slim))};window.MT_SNAP=#{now};window.MT_ARCHN=#{JSON.generate(archn)};" \
           "window.MT_CFG=#{JSON.generate(pub)};window.MT_NPLAT=#{nplat};" \
           "window.MT_PLACES=#{JSON.generate(PLACES.transform_values { |v| v.map(&:first) + [OTHER_PLACE] })};")
SHELL = lambda do |title: nil, desc: nil, path: nil, robots: 'noindex, nofollow', ld: [], route: nil, main: ''|
  e = ->(x) { CGI.escapeHTML(x.to_s) }
  head = tpl_head.sub(/<meta name="robots" content="[^"]*">/) { %(<meta name="robots" content="#{robots}">) }
  if title
    head = head.sub(%r{<title>.*?</title>}m) { "<title>#{e.(title)}</title>" }
               .sub(/<meta property="og:title" content="[^"]*">/) { %(<meta property="og:title" content="#{e.(title)}">) }
  end
  if desc
    head = head.sub(/<meta name="description" content="[^"]*">/) { %(<meta name="description" content="#{e.(desc)}">) }
               .sub(/<meta property="og:description" content="[^"]*">/) { %(<meta property="og:description" content="#{e.(desc)}">) }
  end
  head += %(<link rel="canonical" href="https://monitorg.by#{path}">\n) if path
  head += %(<meta name="mt-route" content="#{e.(route)}">\n) if route
  head += %(<script src="/assets/theme.js?v=#{now}"></script>\n<link rel="stylesheet" href="/assets/site.css?v=#{now}">\n)
  head += ld.map { |x| %(<script type="application/ld+json">#{JSON.generate(x).gsub('</', '<\/')}</script>\n) }.join
  head + body_tpl.sub('<main id="app"></main>') { %(<main id="app">#{main}</main>) } +
    %(<script src="/assets/data.js?v=#{now}"></script>\n<script src="/assets/app.js?v=#{now}"></script>\n)
end
File.write(File.join(OUT, 'index.html'), SHELL.())
File.write(File.join(OUT, 'app.html'), SHELL.())
File.write(File.join(OUT, 'arch.js'), "__arch(#{JSON.generate(arch1.map(&slim))});")
unless ENV['SEO_PAGES'] == '0'
  t0 = Time.now
  r = Pages.run(out: OUT, active: active, arch: arch, details: ->(k) { Store.details(k) }, tree: Cats.tree, now: now,
                shell: SHELL, live: ENV['SEO_LIVE'] == '1')
  puts "SEO-страницы: #{r[:pages]} (открыто поиску #{r[:indexed]}), лотов #{r[:lots]}, срезов #{r[:slices]}, #{(Time.now - t0).round} с"
end
SRCH_ROWS = /\A(?:Адрес \(местонахождение\)|Местоположение имущества|Местонахождение имущества|Местонахождение|Местоположение|Марка|Модель|Марка \(модель\)|Идентификационный номер|Регистрационный номер|Кадастровый номер|Инвентарный номер.*|Инв\. номер|Год выпуска|Год)\z/
DESC_ROWS = /\A(?:Описание(?: имущества)?|Дополнительная информация(?: по всему лоту)?)\z/
srch = order.map do |l|
  rows = Obj.rows_of(Store.details(l['key']))
  ids = Obj.ids(l['name'], rows).map { |x| x.split(':', 2)[1] }
  desc = rows.select { |k, _| k =~ DESC_ROWS }.map { |_, v| v }.join(' ')[0, l['status'] == 'active' ? 300 : 150]
  t = [*rows.select { |k, _| k =~ SRCH_ROWS }.map { |_, v| v }, *ids, *ids.map { |x| x.delete('/-') }, desc].compact.join(' ')
  t = t.gsub(/&#(\d+);/) { $1.to_i.chr('UTF-8') }.downcase.tr('ё', 'е').gsub(/\s+/, ' ').split(' ').uniq.join(' ')
  [l['id'], t] unless t.empty?
end.compact.to_h
old = arch2.map { |l| [l['id'], true] }.to_h
srch2 = srch.select { |id, _| old[id] }
srch.reject! { |id, _| old[id] }
File.write(File.join(OUT, 'srch.js'), "__srch(#{JSON.generate(srch)});")
File.write(File.join(OUT, 'arch2.js'), "__arch2(#{JSON.generate(arch2.map(&slim))},#{JSON.generate(srch2)});")
File.write(File.join(OUT, '.nojekyll'), '')
adm = File.read(File.join(__dir__, 'admin.html'), encoding: 'UTF-8')
FileUtils.cp(File.join(__dir__, 'stats.js'), File.join(OUT, 'stats.js'))
FileUtils.mkdir_p(File.join(OUT, 'api'))
Dir[File.join(__dir__, 'api', '*.php')].each { |f| FileUtils.cp(f, File.join(OUT, 'api', File.basename(f))) }
File.write(File.join(OUT, 'api', 'cfg.php'), "<?php return #{JSON.generate('u' => ENV['SB_URL'], 'k' => ENV['SB_KEY']).gsub("'", '')
  .then { |j| "json_decode('#{j}', true)" }};\n") if Sb.on?
FileUtils.cp_r(File.join(__dir__, 'noph'), File.join(OUT, 'noph'))
FileUtils.cp_r(File.join(__dir__, 'img'), File.join(OUT, 'img'))
FileUtils.cp_r(File.join(__dir__, 'fonts'), File.join(OUT, 'fonts'))
FileUtils.cp_r(File.join(__dir__, 'vendor'), File.join(OUT, 'vendor'))
%w[favicon.svg favicon.ico apple-touch-icon.png admin-icon.svg admin-icon.png admin-icon-180.png logo-mark.png logo-mark-dark.png logo-mail.png].each { |f| FileUtils.cp(File.join(__dir__, f), File.join(OUT, f)) }
FileUtils.cp(File.join(__dir__, 'htaccess'), File.join(OUT, '.htaccess'))
FileUtils.mkdir_p(File.join(OUT, 'docs'))
Dir[File.join(__dir__, 'docs', '*.txt')].each { |f| FileUtils.cp(f, File.join(OUT, 'docs', File.basename(f))) }
File.write(File.join(OUT, 'admin', 'index.html'),
           adm.sub('__SB_URL__') { ENV['SB_URL'].to_s }.sub('__SB_KEY__') { ENV['SB_KEY'].to_s }.sub('__BUILD__', now.to_s).sub('__CATS__') { JSON.generate(Cats.tree) })

published = active.map { |l| [l['key'], true] }.to_h
mirror = lots.map do |l|
  o = orig[l['key']]
  o.merge('photo' => !l['photo'].nil?, 'status' => l['status'], 'closed' => l['closed'], 'why' => l['why'],
          'first_seen' => l['first_seen'], 'city' => l['city'],
          'terms' => l['status'] == 'active' ? raw[l['key']]['terms'] : nil, 'pics' => l['status'] == 'active' ? raw[l['key']]['pics'] : nil,
          'sub' => auto_sub.fetch(l['key'], l['sub']),
          'price0' => (l['prices'] || []).size > 1 ? l['prices'].first[1] : nil,
          'result' => l['result'] && l['result'].reject { |k, _| %w[checked tries].include?(k) },
          'market' => l['market'] && l['market'].slice('median', 'n', 'source', 'low', 'high', 'manual', 'link'),
          'reasons' => reasons[l['key']] || [], 'dup_with' => dup_with[l['key']], 'dup_of' => dup_of[l['key']],
          'alt' => l['alt'], 'published' => published[l['key']] || (l['status'] == 'archive' && !hidden_why[l['key']]),
          'prev' => l['status'] == 'active' ? (sim[l['key']] || {})['prev'] : nil,
          'hidden_why' => hidden_why[l['key']], 'synced' => now)
end
FileUtils.mkdir_p(TMP)
File.write(File.join(TMP, 'mirror.json'), JSON.generate(mirror))
FINAL_ST = %w[sold single failed cancelled].freeze
sales = lots.flat_map do |l|
  ([l['result']] + (l['results'] || [])).compact.select { |r| FINAL_ST.include?(r['st']) }.map do |r|
    { 'key' => l['key'], 'at' => (r['at'] || l['closed'] || l['req_to']).to_i, 'id' => l['id'], 'platform' => l['platform'],
      'section' => l['section'], 'region' => l['region'], 'location' => l['location'], 'name' => l['name'], 'debtor' => l['debtor'],
      'area_num' => l['area_num'], 'url' => l['url'], 'st' => r['st'], 'start' => r['start'], 'price' => r['price'],
      'bids' => r['bids'], 'users' => r['users'] }
  end
end.uniq { |x| [x['key'], x['at']] }
File.write(File.join(TMP, 'sales.json'), JSON.generate(sales))

FileUtils.rm_f(File.join(TMP, 'stats_file.json'))
FileUtils.mkdir_p(File.join(OUT, 'st'))
File.write(File.join(OUT, 'robots.txt'), "User-agent: *\nDisallow: /st/\n\nSitemap: https://monitorg.by/sitemap.xml\n")
File.write(File.join(OUT, "#{IndexNow::KEY}.txt"), IndexNow::KEY)
begin
  File.binwrite(File.join(OUT, 'st', "#{ST_PREV['name']}.bin"), ST_PREV['bytes']) if ST_PREV
  all_sales = (ADM['sales'] + sales).each_with_object({}) { |x, h| h["#{x['key']}|#{x['at'].to_i}"] = x }.values
  rnd = Similar.rounds
  file_sales = all_sales.map do |x|
    r = rnd["#{x['key']}|#{x['at'].to_i}"]
    x.merge('city' => place_of(x['location'], x['region']), 'rnd' => r && r[0], 's1' => r && r[1])
  end
  data = { 'v' => StatsFile::VER, 'at' => now, 'full_at' => sales_full_at,
           'lots' => StatsFile.cols(mirror.sort_by { |l| l['key'] }, StatsFile::LOT_COLS),
           'sales' => StatsFile.cols(file_sales.sort_by { |x| [x['key'], x['at'].to_i] }, StatsFile::SALE_COLS) }
  bytes, key = StatsFile.seal(data)
  StatsFile.open(bytes, key)
  sname = SecureRandom.hex(16)
  File.binwrite(File.join(OUT, 'st', "#{sname}.bin"), bytes)
  File.write(File.join(TMP, 'stats_file.json'), JSON.generate('name' => sname, 'key' => key, 'lots' => mirror.size,
                                                              'sales' => all_sales.size, 'kb' => bytes.size / 1024))
  puts "аналитика: файл #{bytes.size / 1024} КБ — лотов #{mirror.size}, итогов #{all_sales.size}"
rescue StandardError => e
  warn "аналитика: файл не собран (#{e.class}: #{e.message}) — кабинет и админка возьмут прежний или данные из базы"
end
File.write(File.join(TMP, 'build.json'), JSON.generate('published' => active.size, 'queue' => queued, 'merged' => dup_of.size,
                                                        'archive' => arch.size, 'photos' => active.count { |l| l['photo'] }))

by = Hash.new(0)
active.each { |l| by[l['section']] += 1 }
kb = ->(f) { (File.size(File.join(OUT, f)) / 1024.0).round }
puts "активных #{active.size} (#{by.map { |k, v| "#{k} #{v}" }.join(', ')}), в архиве #{arch.size}"
puts "index.html #{kb.('index.html')} КБ, arch.js #{kb.('arch.js')} КБ, arch2.js #{kb.('arch2.js')} КБ, srch.js #{kb.('srch.js')} КБ, пачек #{packs}, " \
     "фото #{order.count { |l| l['photo'] }}, ориентиров #{active.count { |l| l['market'] }}"
