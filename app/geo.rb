# encoding: utf-8
require 'json'
require 'uri'
require_relative 'store'
require_relative 'objects'

module Geo
  module_function

  CACHE = File.join(Store::DATA, 'geo.json')
  UA = 'MoniTorg/1.0 (+https://monitorg.by/)'
  CAP = (ENV['GEO_CAP'] || 900).to_i
  V = 2
  ST = { 'ул' => 'улица', 'улица' => 'улица', 'пр-т' => 'проспект', 'просп' => 'проспект', 'проспект' => 'проспект', 'пр' => 'проспект',
         'пер' => 'переулок', 'переулок' => 'переулок', 'бул' => 'бульвар', 'б-р' => 'бульвар', 'бульвар' => 'бульвар', 'ш' => 'шоссе',
         'шоссе' => 'шоссе', 'пл' => 'площадь', 'площадь' => 'площадь', 'мкр' => 'микрорайон', 'микрорайон' => 'микрорайон',
         'тракт' => 'тракт', 'проезд' => 'проезд', 'пр-д' => 'проезд' }.freeze
  HOUSE = %r{(?:(?:,\s*|\s+(?=д\.|дом|\d+[а-яa-z]?(?:/\d+)?\s*(?:[,;.]|\z)))(?:д\.|дом)?\s*(\d+\s?[а-яa-z]?(?:/\d+)?)(?:-\S+)?(?:\s+кв\.?\s*\d+)?\.?)?\s*(?:[,;]|\z)}i
  STREET = %r{(?:\A|[\s,])(улица|ул|проспект|просп|пр-т|пр-д|пр|переулок|пер|бульвар|бул|б-р|шоссе|ш|площадь|пл|микрорайон|мкр|тракт|проезд)(?![а-я])\.?\s*([^,]+?)#{HOUSE}}i
  INIT = /(?<![А-Яа-я])[А-Я]\.\s*(?=[А-Я])/
  STREET2 = %r{(?:\A|,)\s*([^,]+?)\s+(улица|переулок|проспект|бульвар|площадь|проезд|тракт|шоссе)#{HOUSE}}i
  BARE = /\A\s*,\s*([А-Я][А-Яа-я\-]+(?:\s[А-Я][А-Яа-я\-]+)?)\s*,\s*(?:д\.\s*)?(\d+[а-я]?(?:\/\d+)?)\s*(?:[,.]|\z)/

  STREET_PART = /\A(?:ул\.|улица|пр-т|просп|проспект|пер\.|переулок|бульвар|б-р|шоссе|тракт|проезд|пл\.|площадь|мкр|микрорайон)(?![а-я])|\s(?:улица|шоссе|проспект|переулок|бульвар|тракт|проезд)\z/i
  def bare_town(a)
    if (m = a.match(/(?:\A|[\s,])(?:н\.\s?п\.|(?:гп|аг|рп|пгт)(?=\s))\s*([А-Я][а-я]+(?:-[А-Я][а-я]+)?)/))
      return [m[1], m.end(0)]
    end
    parts = a.split(',').map(&:strip)
    i = parts.index { |p| p =~ STREET_PART } or return nil
    c = i.positive? ? parts[i - 1] : nil
    return nil unless c && c =~ /\A[А-Я][а-я]+(?:[- ][А-Я][а-я]+)?\z/ && c !~ /(?:ская|ский|цкий|ской|кая)\z|обл|район|сельсовет/i
    [c, a.index(c) + c.size]
  end

  def town_of(a)
    m = a.match(Obj::PLACE) or return(bare_town(a) || [a[/(?<![А-Яа-я])Минск(?![а-я])/] && 'Минск', nil])
    t = m[2]
    nx = a[m.end(0)..][/\A\s([А-Я][а-я]+)(?=\s*(?:,|\z))/, 1]
    t = "#{t} #{nx}" if nx && nx !~ /(?:ский|цкий|ской)\z/
    [t, m.end(0) + (nx ? nx.size + 1 : 0)]
  end

  def queries(addr)
    a = addr.to_s.tr('ё', 'е').tr('Ё', 'Е').gsub(/\b\d{6}\b,?/, '').strip
    town, at = town_of(a)
    dist = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+(?:р-н|район)/, 1]
    reg = a =~ /обл/ ? region_of(a) : nil
    unless town
      ss = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+(?:с\/с|сс|сельсовет)(?![а-я])/, 1]
      return ss && dist ? ["#{ss} сельский Совет, #{dist} район"] : []
    end
    rest = at ? a[at..] : a
    out = []
    street = num = nil
    if (s = rest.match(STREET))
      name = s[2].strip.gsub(INIT, '').sub(/\.\s.*\z/, '')
      street = name =~ /(?:шоссе|проспект|переулок|бульвар|тракт|проезд|площадь)\z/i ? name : "#{ST[s[1].downcase]} #{name}"
      num = s[3]&.delete(' ')
    elsif (s = rest.match(STREET2))
      street, num = "#{s[1].strip} #{s[2].downcase}", s[3]&.delete(' ')
    elsif (s = rest.match(BARE)) && s[1] !~ /(?:ский|цкий|ской)\z/
      street, num = s[1], s[2]
    end
    if street
      street = street.gsub(INIT, '').sub(/\s+[А-Я]\.(?:\s?[А-Я]\.)?\z/, '')
      out << "#{town}, #{street}, #{num}" if num
      out << "#{town}, #{street}"
    end
    out << [town, dist && "#{dist} район", reg].compact.join(', ')
    out.uniq
  end

  def ask(q)
    u = 'https://nominatim.openstreetmap.org/search?' +
        URI.encode_www_form(format: 'jsonv2', limit: 1, addressdetails: 1, countrycodes: 'by', 'accept-language' => 'ru', q: q)
    out = IO.popen(['curl', '-sS', '-m', '20', '-A', UA, u], err: File::NULL, &:read)
    r = JSON.parse(out.to_s.force_encoding('UTF-8')).first
    return 0 unless r
    num = q[/[\s,](\d+)[а-яa-z]?(?:\/\d+)?\z/i, 1]
    same = num && r.dig('address', 'house_number').to_s[/\A\d+/] == num
    words = q.split(',')[1].to_s.downcase.split.reject { |w| w.size < 3 || ST.value?(w) }
    on_street = !words.empty? && words.all? { |w| r.dig('address', 'road').to_s.downcase.include?(w) }
    prec = %w[building house].include?(r['addresstype']) || r['category'] == 'building' || same ? 'a' :
           r['addresstype'] == 'road' || r['category'] == 'highway' || on_street ? 's' : 'p'
    [r['lat'].to_f.round(5), r['lon'].to_f.round(5), prec]
  rescue JSON::ParserError
    nil
  end

  def ask_region(key)
    name, kind = key.split('|')
    u = 'https://nominatim.openstreetmap.org/search?' +
        URI.encode_www_form(format: 'jsonv2', limit: 10, addressdetails: 1, countrycodes: 'by', 'accept-language' => 'ru',
                            featureType: 'settlement', q: name)
    out = IO.popen(['curl', '-sS', '-m', '20', '-A', UA, u], err: File::NULL, &:read)
    rs = JSON.parse(out.to_s.force_encoding('UTF-8')).select { |r| r['name'].to_s.tr('ё', 'е') == name }
    rs.select! { |r| %w[city town].include?(r['addresstype']) } if kind == 'т'
    st = rs.map { |r| r.dig('address', 'state').to_s.tr('ё', 'е') }.uniq
    return 0 unless st.size == 1
    st[0] == 'Минск' ? 'г. Минск' : st[0] =~ /\A[А-Я][а-я]+ская область\z/ ? st[0] : 0
  rescue JSON::ParserError
    nil
  end

  def run(db, stat, stop)
    cache = File.exist?(CACHE) ? (JSON.parse(File.read(CACHE, encoding: 'UTF-8')) rescue {}) : {}
    asked = 0
    no_reg = db.values.select { |l| l['platform'] != 'konfiskat.by' && region_of(l['location']).empty? }
    keys = no_reg.map { |l| place_key(l['location']) }.compact.uniq.reject { |k| place_reg.key?(k) }
    keys.each do |k|
      break if asked >= CAP || Time.now > stop
      r = ask_region(k)
      asked += 1
      sleep 1.1
      place_reg[k] = r unless r.nil?
    end
    unless keys.empty?
      File.write(PLACE_REG_FILE, JSON.generate(place_reg))
      no_reg.each { |l| l['region'] = region_of(l['location']) }
    end
    todo = db.values.select { |l| l['status'] == 'active' && l['geo_try'].to_i < 2 &&
                                  (!l.key?('geo') || (l['geo_v'] != V && (l['geo'].nil? || l['geo'][2] == 'p')) ||
                                   (l['platform'] == 'konfiskat.by' && l['geo'].nil? && !l['geo_q'] && Obj.kf_name_addr(l['name'])) ||
                                   ((l['geo'].nil? || l['geo'][2] == 'p') && l['geo_t'] != 1)) }
    todo.each do |l|
      break if asked >= CAP || Time.now > stop
      addr = l['platform'] == 'konfiskat.by' ? Obj.kf_addr(l['name'], Obj.rows_of(Store.details(l['key']))) : l['location']
      l['geo_q'] = addr if l['platform'] == 'konfiskat.by' && addr
      l['geo_t'] = 1
      qs = queries(addr)
      l['geo_v'] = V
      if qs.empty?
        l['geo'] = nil
        next
      end
      keys = qs.each_with_index.map { |q, i| i < qs.size - 1 ? "#{V}|#{q}" : q }
      hit = nil
      failed = false
      qs.each_with_index do |q, i|
        k = keys[i]
        unless cache.key?(k)
          break if asked >= CAP
          r = ask(q)
          asked += 1
          sleep 1.1
          if r.nil?
            failed = true
            break
          end
          cache[k] = r
        end
        (hit = cache[k]) && hit != 0 && break
        hit = nil
      end
      if hit
        l['geo'] = hit
        stat['на карте: найден адрес'] += 1
      elsif failed || !keys.all? { |k| cache.key?(k) }
        l.delete('geo_v')
        l['geo_try'] = l['geo_try'].to_i + 1
      else
        l['geo'] = nil
        stat['на карте: адрес не найден'] += 1
      end
    end
    File.write(CACHE, JSON.generate(cache))
    STDERR.puts "карта: запросов к OpenStreetMap #{asked}, в кеше #{cache.size}"
  end
end
