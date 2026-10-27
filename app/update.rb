#!/usr/bin/env ruby
# encoding: utf-8
require_relative 'sources'
require_relative 'regions'
require_relative 'store'
require_relative 'sb'
require_relative 'results'
require_relative 'backfill'
require_relative 'geo'
require_relative 'pics'
require_relative 'mgcn'
require_relative 'bav'
require 'fileutils'

RETAIN_DAYS = (ENV['RETAIN_DAYS'] || 548).to_i
MAXV = 800
WORKERS = { 'e-auction.by' => 3, 'ipmtorgi.by' => 2, 'beltorgi.by' => 3, 'konfiskat.by' => 1, 'belauction.by' => 1,
            'minskestate.by' => 1, 'mgcn.by' => 1, 'auction24.by' => 1, 'lotsale.by' => 1, 'butb.by' => 1, 'gostorg.by' => 2,
            'bankrot-torg.by' => 1, 'specrealization.by' => 1, 'torgi.gov.by' => 1, 'etpvit.by' => 1, 'expert-torgi.by' => 1, 'realtorgi.by' => 1,
            'iintorgi.by' => 1 }.freeze
NEW_CAP = { 'gostorg.by' => 250, 'torgi.gov.by' => 200 }.freeze
ABROAD = /Нерезидент|Российская Федерация|(?<![А-Яа-я])(?:Россия|РФ|Украина|Литва|Латвия|Польша|Казахстан)(?![А-Яа-я])|г\.\s*(?:Москва|Санкт-Петербург)(?![а-я])|(?:Московская|Ленинградская|Смоленская|Брянская|Псковская) обл/
CLOSED_FILE = File.join(Store::DATA, 'closed.json')
MIN_PRICE = { 'oborud' => 500 }.freeze
CFG = begin
  Sb.on? ? Sb.settings : {}
rescue StandardError => e
  STDERR.puts "настройки админки не прочитаны: #{e.message}"
  {}
end
PLAT_OFF = (CFG['platforms'] || {}).select { |_, v| v == false }.keys
MINP = MIN_PRICE.merge((CFG['min_price'] || {}).map { |k, v| [k, v.to_f] }.to_h)
TERMS_CAP = (ENV['TERMS_CAP'] || 800).to_i
TERMS_V = { 'beltorgi.by' => 2, 'torgi.gov.by' => 3, 'etpvit.by' => 4, 'expert-torgi.by' => 3, 'realtorgi.by' => 3,
            'iintorgi.by' => 3, 'lotsale.by' => 3, 'gostorg.by' => 3 }.freeze
EA_TORG_CAP = (ENV['EA_TORG_CAP'] || 700).to_i
RES_CAP = (ENV['RES_CAP'] || 300).to_i
RESULTS_ONLY = !ENV['RESULTS_ONLY'].to_s.empty?
if YEAR_ARCH && (year_left.empty? || (YEAR_UNTIL && YEAR_UNTIL - Time.now < 30 * 60))
  puts year_left.empty? ? 'архив площадок за год уже загружен — делать нечего' : 'ночной архив запущен GitHub слишком поздно — до утра не успеть, ждём следующей ночи'
  File.write(ENV['GITHUB_OUTPUT'], "work=false\n", mode: 'a') if ENV['GITHUB_OUTPUT']
  exit
end
SWEEP = 1

SEC_RU = { 'nedvizhimost' => 'Недвижимость', 'avto' => 'Легковые авто', 'gruz' => 'Грузовые и автобусы',
           'spec' => 'Спецтехника', 'oborud' => 'Оборудование', 'arenda' => 'Право аренды' }.freeze

PLAN = {
  'e-auction.by' => [['/nedvizhimost/', 'nedvizhimost'], ['/legkovye_avtomobili/', 'avto'],
                     ['/gruzovaya_tekhnika_i_avtobusy/', 'gruz'], ['/spetstekhnika/', 'spec'],
                     ['/stanki_i_oborudovanie/', 'oborud']],
  'ipmtorgi.by'  => [['/auctions/nedvizhimost/', 'nedvizhimost'], ['/auctions/transport-i-spetstekhnika/', nil],
                     ['/auctions/stanki-oborudovanie/', 'oborud']],
  'beltorgi.by'  => [['nedvizhimost', 'nedvizhimost'], ['legkovye-avto', 'avto'], ['gruzovye-avto', 'gruz'],
                     ['avtobusy', 'gruz'], ['specztexnika', 'spec'], ['stanki-i-oborudovanie', 'oborud']],
  'konfiskat.by' => [['avtotransport/auktsiony', 'auto'], ['nedvizhimost/auktsiony', 'nedvizhimost'],
                     ['own-property/auctions', 'oborud']],
  'belauction.by' => [['active', nil]],
  'minskestate.by' => [['commerce', nil]],
  'mgcn.by' => [['rent', 'arenda'], ['place', nil], ['sale', 'nedvizhimost']],
  'auction24.by' => [['catalog', nil]],
  'lotsale.by' => [['auctions', nil]],
  'butb.by' => [['auctions', nil]],
  'gostorg.by' => [['catalog', nil]],
  'bankrot-torg.by' => [['auctions', nil]],
  'specrealization.by' => [['auctions', nil]],
  'torgi.gov.by' => [['lots', nil]],
  'etpvit.by' => [['catalog', nil]],
  'expert-torgi.by' => [['auctions', nil]],
  'realtorgi.by' => [['auctions', nil]],
  'iintorgi.by' => [['lots', nil]]
}.freeze
DROPPED = %w[cpo.by].freeze

def ipm_kind(name)
  n = name.downcase
  return 'avto' if n.start_with?('легков')
  return 'spec' if n =~ /тракторн|мотоблоч/
  return 'gruz' if n =~ /\A(грузов|автобус|полуприцеп|прицеп|автомобиль\s|автомашина)/
  'spec'
end

def kf_kind(name)
  name.downcase =~ /грузов|тягач|самосвал|автобус|прицеп|фургон|рефрижер|бортов|цистерн|\bмаз\b|камаз|\bmaz\b|kamaz|scania|\bdaf\b|\bman\b|iveco|actros|atego|magnum/ ? 'gruz' : 'avto'
end

def list(plat, path)
  case plat
  when 'e-auction.by' then Src.ea_list(path)
  when 'ipmtorgi.by'  then Src.ipm_list(path)
  when 'konfiskat.by' then Src.kf_list(path)
  when 'belauction.by' then Src.ba_list(:active)
  when 'minskestate.by' then Src.me_list
  when 'mgcn.by' then Mg.list(path)
  when 'auction24.by' then Src.a24_list
  when 'lotsale.by' then Src.ls_list
  when 'butb.by' then Src.bu_list
  when 'gostorg.by' then Src.gs_list
  when 'bankrot-torg.by', 'specrealization.by' then Src.vl_list(plat)
  when 'torgi.gov.by' then Src.tg_list
  when 'etpvit.by' then Src.ev_list
  when 'expert-torgi.by', 'realtorgi.by' then Src.jm_list(plat)
  when 'iintorgi.by' then Src.ii_list
  else Src.bt_list(path)
  end
end

def fetch_detail(c)
  return c['d'] if %w[mgcn.by lotsale.by iintorgi.by].include?(c['platform'])
  return Src.tg_detail(c) if c['platform'] == 'torgi.gov.by'
  html = Src.get(c['url']) or return nil
  d = case c['platform']
      when 'e-auction.by' then Src.ea_detail(html)
      when 'ipmtorgi.by'  then Src.ipm_detail(html)
      when 'konfiskat.by' then Src.kf_detail(html, c)
      when 'belauction.by' then Src.ba_detail(html)
      when 'minskestate.by' then Src.me_detail(html)
      when 'auction24.by' then Src.a24_detail(html)
      when 'butb.by' then Src.bu_detail(html)
      when 'gostorg.by' then Src.gs_detail(html)
      when 'bankrot-torg.by', 'specrealization.by' then Src.vl_detail(c['platform'], html)
      when 'etpvit.by' then Src.ev_detail(html)
      when 'expert-torgi.by', 'realtorgi.by' then Src.jm_detail(c['platform'], html)
      else Src.bt_detail(html)
      end
  sleep({ 'konfiskat.by' => 1.5, 'belauction.by' => 2, 'minskestate.by' => 1, 'auction24.by' => 1, 'butb.by' => 1, 'gostorg.by' => 1,
          'bankrot-torg.by' => 1, 'specrealization.by' => 1 }[c['platform']] || 0.4)
  d
end

def trim(secs)
  secs.map do |s|
    { 'h' => s['h'], 'rows' => s['rows'].map { |k, v| [k, v.length > MAXV ? v[0, MAXV].sub(/\s\S*\z/, '') + '…' : v] } }
  end
end

def new_lot(c, sec, d, src, now)
  plat = c['platform']
  loc = plat == 'ipmtorgi.by' ? c['location'].to_s : d['location'].to_s
  if plat == 'beltorgi.by' && loc !~ /обл|г\.\s*Минск/
    loc = [c['region'], loc].reject { |x| x.to_s.empty? }.join(', ')
  end
  price = c['price'].to_f.positive? ? c['price'] : d['price_byn'].to_f
  { 'key' => c['key'], 'status' => 'active', 'src' => src, 'first_seen' => now, 'last_seen' => now,
    'art' => plat == 'ipmtorgi.by' && !d['lotno'].to_s.empty? ? d['lotno'] : (c['art'] || d['art']),
    'name' => plat == 'beltorgi.by' && !d['title'].to_s.empty? ? d['title'] : %w[butb.by gostorg.by].include?(plat) && !d['name'].to_s.empty? ? d['name'] : c['name'],
    'price' => price, 'prices' => [[now, price]],
    'req_to' => plat == 'e-auction.by' ? c['req_to'] : (d['req_to'] || c['req_to']),
    'torg' => d['torg'], 'url' => c['url'], 'location' => loc, 'region' => region_of(loc),
    'debtor' => d['debtor'], 'area_num' => %w[nedvizhimost arenda].include?(sec) ? d['area_num'] : nil,
    'sub_ru' => plat == 'e-auction.by' && sec == 'nedvizhimost' ? Src::EA_SUBS[c['sub']] : nil,
    'platform' => plat, 'section' => sec, 'section_ru' => SEC_RU[sec], 'terms' => d['terms'] || {} }
    .tap do |r|
      r['pics'] = d['photos'] if d['photos']
      r['phx'] = c['phx'] if c['phx']
      r['rent'] = d['rent'] if d['rent']
      r['off'] = true if c['off'] || d['off']
    end
end

now = Time.now.to_i
t0 = Time.now
db = Store.load.each_with_object({}) { |l, h| h[l['key']] = l }
Dir[File.join(Store::PH, 'bu-*.jpg')].each { |f| File.delete(f) if Store.nophoto?(f) }
dropped = 0
db.delete_if do |k, l|
  next false unless DROPPED.include?(l['platform'])
  [Store.det_path(k), Store.ph_path(k)].each { |x| File.delete(x) if File.exist?(x) }
  dropped += 1
end
before = db.values.count { |l| l['status'] == 'active' }
mx = Mutex.new
seen = {}
lists = {}
bav_mg = []
stat = Hash.new(0)
pstat = Hash.new { |h, k| h[k] = Hash.new(0) }
terms_left = TERMS_CAP
new_left = NEW_CAP.dup
closed = File.exist?(CLOSED_FILE) ? (JSON.parse(File.read(CLOSED_FILE, encoding: 'UTF-8')) rescue {}) : {}
closed.reject! { |_, t| t.to_i < now - 30 * 86_400 }
ea_torg_left = EA_TORG_CAP
torg_left = 300
stat['удалено: площадка исключена'] = dropped if dropped.positive?
db.each_value do |l|
  %w[name location debtor].each { |k| l[k] = Src.decode(l[k]) if l[k].is_a?(String) && l[k] =~ /&#?\w+;/ }
  l['rent'] = { 'k' => 'raw', 'raw' => l['rent']['raw'] } if l['platform'] == 'gostorg.by' && l['rent'].is_a?(Hash) && l['rent']['k'] == 'ks'
end

(RESULTS_ONLY || YEAR_ARCH ? {} : PLAN.reject { |plat, _| PLAT_OFF.include?(plat) }).map do |plat, secs|
  Thread.new do
    todo = Queue.new
    secs.each do |path, sec|
      src = "#{plat} #{path}"
      cards = list(plat, path)
      mx.synchronize do
        lists[src] = cards.nil? || (cards.empty? && !%w[mgcn.by konfiskat.by lotsale.by].include?(plat)) ? nil : cards.size
        (cards || []).each { |c| seen[c['key']] = true }
        (cards || []).each { |c| bav_mg << (c['bav'] + [c['url']]) if c['bav'] }
      end
      cards ||= []
      STDERR.puts "#{src}: в списке #{cards.size}"
      cards.each do |c|
        next if plat == 'beltorgi.by' && !c['open']
        next if plat == 'minskestate.by' && c['status'] !~ /Приём заявок/
        next if plat == 'butb.by' && c['status'] !~ /Прием заявлений/
        next if %w[expert-torgi.by realtorgi.by].include?(plat) && c['status'] !~ /Предстоящ|Прием|Приём|Идут/i
        next if closed[c['key']] && !db[c['key']]
        next if c['day'] && plat == 'konfiskat.by' && c['day'] - 12 * 3600 < Time.now.to_i
        s = c['sec'] || (sec == 'auto' ? kf_kind(c['name']) : (sec || ipm_kind(c['name'])))
        min = MINP[s].to_f
        next if min.positive? && c['price'].to_f.positive? && c['price'] < min
        todo << [c, s, src]
      end
    end
    Array.new(WORKERS[plat]) do
      Thread.new do
        loop do
          c, sec, src = begin
            todo.pop(true)
          rescue ThreadError
            break
          end
          old = mx.synchronize { db[c['key']] }
          if old
            upd = {}
            if !old.key?('terms') || old['terms']['v'].to_i < TERMS_V.fetch(c['platform'], 0)
              go = mx.synchronize { (terms_left -= 1) >= 0 }
              if go
                if c['platform'] == 'beltorgi.by'
                  upd['terms'] = Src.bt_terms(Store.details(c['key']))
                elsif c['platform'] == 'torgi.gov.by'
                  upd['terms'] = (old['terms'] || {}).merge(c['d']['terms'])
                elsif c['platform'] == 'gostorg.by'
                  fee = Store.details(c['key']).flat_map { |s| Array(s['rows']) }.find { |k, _| k == 'Затраты и вознаграждение' }&.last
                  upd['terms'] = (old['terms'] || {}).merge('fee_pct' => Src.gs_fee_pct(fee), 'v' => 3).merge(Src.gs_fee_abs(fee)).reject { |_, v| v.nil? }
                elsif (d2 = fetch_detail(c))
                  upd['terms'] = d2['terms'] || {}
                  upd['torg'] = d2['torg'] if c['platform'] == 'etpvit.by' && d2['torg']
                end
                mx.synchronize { stat['дозаполнены условия'] += 1 }
              end
            end
            if c['platform'] == 'mgcn.by'
              Store.save_details(c['key'], trim(c['d']['details']))
              upd['rent'] = c['d']['rent'] if c['d']['rent']
              upd['torg'] = c['torg'] if c['torg']
            end
            if !old['photo'] && (old['ph_try'].to_i < 3 || now - old['ph_at'].to_i > 86_400) &&
               !File.exist?(Store.ph_path(c['key'])) && !%w[minskestate.by mgcn.by].include?(c['platform'])
              d3 = fetch_detail(c)
              ok = Store.save_photo([d3 && (d3['photo_url'] || (d3['photos'] || [])[0]), c['thumb']], c['key'], Src::UA)
              upd['photo'] = ok
              upd['ph_try'] = old['ph_try'].to_i + 1 unless ok
              upd['ph_at'] = now
              upd['pics'] = d3['photos'] if d3 && (d3['photos'] || []).any?
              mx.synchronize { stat[ok ? 'фото докачано' : 'фото не нашлось'] += 1 }
            end
            if c['platform'] == 'konfiskat.by' && old['location'].to_s.empty? && old['kf_try'].to_i < 3
              d4 = fetch_detail(c)
              if d4 && d4['location']
                upd.merge!('location' => d4['location'], 'region' => region_of(d4['location']), 'req_to' => d4['req_to'], 'torg' => d4['torg'])
                Store.save_details(c['key'], trim(d4['details'] || []))
                mx.synchronize { stat['konfiskat: извещение дочитано'] += 1 }
              else
                upd['kf_try'] = old['kf_try'].to_i + 1
              end
            end
            upd['eid'] = c['eid'] if c['eid'] && !old['eid']
            if c['platform'] == 'e-auction.by' && !old['torg'] && (c['eid'] || old['eid']) && mx.synchronize { (ea_torg_left -= 1) >= 0 }
              t = Res.ea_torg(Res.ea_info(c['eid'] || old['eid']))
              upd['torg'] = t if t
              sleep 0.3
            end
            upd['price'] = c['price'] if c['price'].to_f.positive? && c['price'] != old['price']
            if c['platform'] == 'beltorgi.by'
              if c['est'] && (c['est'] - old['req_to'].to_i).abs > 86_400
                d = fetch_detail(c)
                if d && d['req_to']
                  upd['req_to'] = d['req_to']
                  upd['torg'] = d['torg']
                  upd['terms'] = d['terms'] if d['terms']
                  Store.save_details(c['key'], trim(d['details'] || []))
                end
              end
            elsif c['req_to'].to_i.positive? && c['req_to'] != old['req_to']
              upd['req_to'] = c['req_to']
            end
            rq = (upd['req_to'] || old['req_to']).to_i
            if old['torg'].to_i.positive? && old['torg'].to_i < rq - 60 && !upd.key?('torg') && mx.synchronize { (torg_left -= 1) >= 0 }
              if c['platform'] == 'e-auction.by'
                upd['torg'] = nil
              elsif (d5 = fetch_detail(c))
                upd['torg'] = d5['torg'].to_i > rq - 60 ? d5['torg'] : nil
              end
              mx.synchronize { stat['дата торгов перечитана'] += 1 }
            end
            mx.synchronize do
              if upd['price']
                (old['prices'] ||= [[old['first_seen'], old['price']]]) << [now, upd['price']]
                stat['цена изменилась'] += 1
              end
              old.merge!(upd)
              old['last_seen'] = now
              if old['status'] == 'archive' && old['req_to'].to_i > now
                old['status'] = 'active'
                (old['results'] ||= []) << old.delete('result') if old['result']
                old['reopened'] = now
                old.delete('closed')
                old.delete('why')
                stat['вернулись из архива'] += 1
              end
            end
          else
            next if NEW_CAP[c['platform']] && mx.synchronize { (new_left[c['platform']] -= 1).negative? }
            d = fetch_detail(c) or next
            if d['skip']
              mx.synchronize { closed[c['key']] = now }
              next
            end
            if d['sec'] && d['sec'] != sec
              sec = d['sec']
              min = MINP[sec].to_f
              next if min.positive? && d['price_byn'].to_f.positive? && d['price_byn'] < min
            end
            rec = new_lot(c, sec, d, src, now)
            if rec['location'] =~ ABROAD
              mx.synchronize { closed[c['key']] = now }
              next
            end
            unless rec['req_to'].to_i > now
              mx.synchronize { closed[c['key']] = rec['req_to'].to_i.positive? ? rec['req_to'] : now } if NEW_CAP[c['platform']]
              next
            end
            if %w[e-auction.by etpvit.by].include?(plat) && c['eid']
              rec['eid'] = c['eid']
              t = !(plat == 'etpvit.by' && rec['torg']) && Res.ea_torg(Res.ea_info(c['eid'], plat == 'etpvit.by' ? Src::EV : Src::EA))
              rec['torg'] = t if t
            end
            rec['tk'] = d['tk'] if d['tk']
            Store.save_details(c['key'], trim(d['details'] || []))
            rec['photo'] = Store.save_photo([d['photo_url'], c['thumb']], c['key'], Src::UA) unless %w[minskestate.by mgcn.by].include?(plat)
            mx.synchronize do
              db[c['key']] = rec
              stat['новых'] += 1
              pstat[plat]['new'] += 1
            end
          end
        end
      end
    end.each(&:join)
  end
end.each(&:join)

unless RESULTS_ONLY || YEAR_ARCH
  sig = lambda do |l|
    rows = Obj.rows_of(Store.details(l['key']))
    Obj.ids(l['name'], rows).select { |x| x.start_with?('inv:') } + [l['location'].to_s.downcase.gsub(/г\.\s*минск|[^а-яa-z0-9]/, '')]
  end
  me = db.values.select { |l| l['platform'] == 'minskestate.by' && l['status'] == 'active' }.flat_map(&sig).reject(&:empty?)
  db.delete_if do |k, l|
    next false unless l['platform'] == 'mgcn.by' && l['section'] == 'nedvizhimost' && l['status'] == 'active' && (sig.(l) & me).any?
    File.delete(Store.det_path(k)) if File.exist?(Store.det_path(k))
    stat['МГЦН: есть на minskestate.by'] += 1
  end
  Bav.run(bav_mg)
end

RENT_RIGHT = /\A[^а-яё]*(?:право\s+(?:на\s+)?заключени\S*\s+договор\S*\s+аренды|прав[оа]\s+аренды)/i
db.each_value do |l|
  next unless l['section'] == 'nedvizhimost' && l['name'].to_s =~ RENT_RIGHT
  l['section'] = 'arenda'
  l['section_ru'] = SEC_RU['arenda']
  stat['право аренды: из недвижимости'] += 1
end

unless RESULTS_ONLY || YEAR_ARCH
  kf = db.values.select { |l| l['platform'] == 'konfiskat.by' && l['status'] == 'active' && !l['tk_chk'] }
  re_cat = nil
  norm = ->(s) { s.to_s.downcase.gsub(/[^а-яёa-z0-9]/, '')[0, 80] }
  kf.each do |l|
    if l['section'] == 'nedvizhimost'
      re_cat ||= Src.tk_re_list or break
      m = re_cat.find { |c| norm.(c['name']) == norm.(l['name']) }
      l['tk'] = m && m['url']
      t = m && m['torg']
      if m && (html = Src.get(m['url'])) && (rq = Src.tk_req_to(html)) && rq > now && rq != l['req_to']
        STDERR.puts "konfiskat #{l['key']}: срок заявок → #{Time.at(rq).strftime('%d.%m %H:%M')}"
        l['req_to'] = rq
        secs = Store.details(l['key'])
        secs.each { |sx| (sx['rows'] || []).each { |r| r[1] = Time.at(rq).strftime('%d.%m.%Y %H:%M') if r[0] == 'Приём заявок до' } }
        Store.save_details(l['key'], secs)
      end
    else
      html = l['tk'] && Src.get(l['tk'])
      next unless html
      (l.delete('tk'); l['tk_chk'] = now; next) if Src.tk_lot(html) && Src.tk_lot(html) != l['art'].to_s
      t = Src.tk_start(html)
    end
    l['tk_chk'] = now
    next unless t && t > now && t != l['torg']
    STDERR.puts "konfiskat #{l['key']}: время торгов #{Time.at(l['torg'].to_i).strftime('%d.%m %H:%M')} → #{Time.at(t).strftime('%d.%m %H:%M')}"
    l['torg'] = t
    secs = Store.details(l['key'])
    secs.each { |sx| (sx['rows'] || []).each { |r| r[1] = Time.at(t).strftime('%d.%m.%Y %H:%M') if r[0] == 'Дата аукциона' } }
    Store.save_details(l['key'], secs)
  end
end

if lists['belauction.by active']
  db.values.select { |l| l['status'] == 'active' && l['platform'] == 'belauction.by' && !seen[l['key']] }.first(12).each do |l|
    sleep 2
    html = Src.get(l['url']) or next
    r = Res.ba_result(html)
    end_t = html[/id=ending[^>]*>\s*(\d{9,})/, 1].to_i
    end_t = Src.ru_date(Res.text(html)[/Завершение торгов:\s*(\d{1,2} [а-я]+ \d{4})/, 1]).to_i unless end_t.positive?
    if r['st'] != 'pending'
      t = end_t.positive? && end_t < now ? end_t : now
      l.merge!('status' => 'archive', 'closed' => t, 'why' => 'deadline', 'req_to' => t, 'torg' => t,
               'result' => r.merge('checked' => now, 'tries' => 1, 'sweep' => SWEEP))
      stat['belauction: торги закрыты раньше срока'] += 1
      pstat['belauction.by']['archived'] += 1
    elsif end_t.positive? && (end_t - l['req_to'].to_i).abs > 3600
      l['req_to'] = l['torg'] = end_t
      stat['belauction: срок уточнён по странице лота'] += 1
    end
  end
end

active_by_src = Hash.new(0)
db.each_value { |l| active_by_src[l['src']] += 1 if l['status'] == 'active' }
db.each_value do |l|
  next unless l['status'] == 'active'
  if l['req_to'].to_i <= now
    l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
    stat['в архив: срок истёк'] += 1
    pstat[l['platform']]['archived'] += 1
  elsif !seen[l['key']] && l['platform'] != 'belauction.by'
    n = lists[l['src']]
    next if n.nil? || n < active_by_src[l['src']] / 2
    l.merge!('status' => 'archive', 'closed' => now, 'why' => 'removed')
    stat['в архив: снят с площадки'] += 1
    pstat[l['platform']]['archived'] += 1
  end
end

def fetch_result(l)
  case l['platform']
  when 'e-auction.by'
    eid = l['eid'] || ((html = Src.get(l['url'])) && Res.ea_eid(html))
    eid ? [Res.ea_result(Res.ea_info(eid)), { 'eid' => eid }] : [nil, {}]
  when 'ipmtorgi.by'
    html = Src.get(l['url']) or return [nil, {}]
    all = Res.ipm_all_bids(html)
    [Res.ipm_result(html, all), {}]
  when 'beltorgi.by'
    (html = Src.get(l['url'])) ? [Res.bt_result(html), {}] : [nil, {}]
  when 'konfiskat.by'
    tk = l['tk'] || ((html = Src.get(l['url'])) && Res.kf_tk_url(html))
    return [nil, {}] unless tk
    sleep 1.5
    (html = Src.get(tk)) ? [Res.tk_result(html), { 'tk' => tk }] : [nil, { 'tk' => tk }]
  when 'belauction.by'
    sleep 2
    (html = Src.get(l['url'])) ? [Res.ba_result(html), {}] : [nil, {}]
  when 'minskestate.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.me_result(html), {}] : [nil, {}]
  when 'auction24.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.a24_result(html), {}] : [nil, {}]
  when 'lotsale.by'
    sleep 0.5
    (a = Src.ls_json("/auctions/#{l['art']}/public")) ? [Res.ls_result(a), {}] : [nil, {}]
  when 'butb.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.bu_result(html), {}] : [nil, {}]
  when 'gostorg.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.gs_result(html), {}] : [nil, {}]
  when 'bankrot-torg.by', 'specrealization.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.vl_result(html), {}] : [nil, {}]
  when 'expert-torgi.by', 'realtorgi.by'
    sleep 1
    (html = Src.get(l['url'])) ? [Res.jm_result(html), {}] : [nil, {}]
  when 'iintorgi.by'
    sleep 1
    x = (JSON.parse(Src.get("#{Src::II}/admin/api/admin/lot/#{l['key'].sub('ii-', '')}", min: 2).to_s)['data'] rescue nil)
    x = x.first if x.is_a?(Array)
    x ? [Res.ii_result(x), {}] : [nil, {}]
  when 'etpvit.by'
    sleep 1
    l['eid'] ? [Res.ea_result(Res.ea_info(l['eid'], Src::EV)), {}] : [nil, {}]
  when 'torgi.gov.by'
    sleep 3
    auc = l['url'].to_s[%r{/lot/\d+/(\d+)}, 1]
    (a = auc && Src.tg_json("/auctions/#{auc}/lot/#{l['art']}/public")) ? [Res.tg_result(a, l['art']), {}] : [nil, {}]
  else [nil, {}]
  end
rescue StandardError => e
  STDERR.puts "итоги #{l['key']}: ошибка #{e.message}"
  [nil, {}]
end

due = db.values.select do |l|
  next false unless l['status'] == 'archive' && l['why'] == 'deadline'
  next false if l['platform'] == 'mgcn.by' || l['off']
  r = l['result'] || {}
  next false if Res::FINAL.include?(r['st']) && r['v'].to_i >= 2
  age = now - (l['torg'] || l['req_to'].to_i + 86_400)
  next false if age < 1800
  next r['sweep'].to_i < SWEEP if age > 21 * 86_400
  gap = age < 2 * 86_400 ? 50 * 60 : age < 7 * 86_400 ? 6 * 3600 : 20 * 3600
  now - r['checked'].to_i >= gap
end.sort_by { |l| -(l['torg'] || l['req_to']).to_i }.first(YEAR_ARCH ? 0 : RES_CAP)
STDERR.puts "итоги торгов: проверяю #{due.size}" unless due.empty?
RES_THREADS = { 'ipmtorgi.by' => 3, 'e-auction.by' => 2 }.freeze
due.group_by { |l| l['platform'] }.flat_map { |plat, ls| ls.each_slice((ls.size / (RES_THREADS[plat] || 1).to_f).ceil).map { |part| [plat, part] } }.map do |plat, ls|
  Thread.new do
    dead = 0
    ls.each_with_index do |l, i|
      if dead >= 2
        STDERR.puts "итоги: #{plat} не отвечает — пропускаю #{ls.size - i}"
        break
      end
      t1 = Time.now
      r, extra = fetch_result(l)
      dead = r.nil? && Time.now - t1 > 60 ? dead + 1 : 0
      mx.synchronize do
        l.merge!(extra)
        tries = (l['result'] || {})['tries'].to_i + 1
        l['result'] = (r || l['result'] || { 'st' => 'pending' }).merge('checked' => now, 'tries' => tries, 'sweep' => SWEEP)
        if Res::FINAL.include?(l['result']['st'])
          stat["итоги: #{{ 'sold' => 'продан', 'single' => 'продан единственному', 'failed' => 'не состоялись', 'cancelled' => 'отменены' }[l['result']['st']]}"] += 1
          pstat[plat]['results'] += 1
        end
      end
      sleep plat == 'konfiskat.by' ? 1.5 : 0.5
    end
  end
end.each(&:join)

if YEAR_ARCH
  backfill(db, stat, pstat, now)
elsif !RESULTS_ONLY
  geo_t = Thread.new do
    Geo.run(db, stat, Time.now + BACK_MIN * 60)
  rescue StandardError => e
    STDERR.puts "карта: ошибка #{e.message}"
  end
  backfill(db, stat, pstat, now)
  geo_t.join

  fill_pics(db, stat)
end

cut = now - RETAIN_DAYS * 86_400
db.delete_if do |k, l|
  abroad = l['location'].to_s =~ ABROAD
  next false unless abroad || (l['status'] == 'archive' && l['closed'].to_i < cut)
  [Store.det_path(k), Store.ph_path(k)].each { |f| File.delete(f) if File.exist?(f) }
  stat[abroad ? 'не в Беларуси — удалено' : 'удалено из архива'] += 1
  true
end

Store.save(db.values)
File.write(CLOSED_FILE, JSON.generate(closed)) unless RESULTS_ONLY || YEAR_ARCH
act = db.values.count { |l| l['status'] == 'active' }
FileUtils.mkdir_p(File.join(Store::ROOT, 'tmp'))
File.write(File.join(Store::ROOT, 'tmp', 'run.json'), JSON.generate(
  'platforms' => pstat, 'stat' => stat, 'unread' => lists.select { |_, n| n.nil? }.keys, 'off' => PLAT_OFF,
  'active_before' => before, 'active' => act, 'archive' => db.size - act, 'minutes' => ((Time.now - t0) / 60).round(1)))
STDERR.puts stat.map { |k, v| "#{k}: #{v}" }.join(', ') unless stat.empty?
STDERR.puts "активных #{before} → #{act}, в архиве #{db.size - act}, за #{((Time.now - t0) / 60).round(1)} мин"
abort('подозрительно мало активных лотов — проверьте парсеры') if act < 100
