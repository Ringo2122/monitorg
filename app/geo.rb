# encoding: utf-8
#
# Карта на странице активного лота: адрес с площадки → координаты. Сервис — OpenStreetMap Nominatim
# (бесплатный; правила: не чаще раза в секунду, понятный User-Agent, кешировать). Кеш — data/geo.json:
# один и тот же адрес или населённый пункт второй раз не спрашиваем.
# Площадки пишут адрес длинно («Брестская область, Пинский р-н, г. Пинск, ул. Рокоссовского, 1») — так
# Nominatim не находит. Спрашиваем от точного к общему: «город, улица, дом» → «город, улица» → «пункт, район, область».
# У лота — geo: [широта, долгота, точность]: a — дом, s — улица, p — населённый пункт.
# konfiskat: адрес торгов — не место машины; берём «На хранении: …» из описания, нет его — карты нет.
require 'json'
require 'uri'
require_relative 'store'
require_relative 'objects'

module Geo
  module_function

  CACHE = File.join(Store::DATA, 'geo.json')
  UA = 'MoniTorg/1.0 (+https://monitorg.by/)'
  CAP = (ENV['GEO_CAP'] || 900).to_i   # запросов к сервису за прогон
  V = 2   # версия разбора адреса
  ST = { 'ул' => 'улица', 'улица' => 'улица', 'пр-т' => 'проспект', 'просп' => 'проспект', 'проспект' => 'проспект', 'пр' => 'проспект',
         'пер' => 'переулок', 'переулок' => 'переулок', 'бул' => 'бульвар', 'б-р' => 'бульвар', 'бульвар' => 'бульвар', 'ш' => 'шоссе',
         'шоссе' => 'шоссе', 'пл' => 'площадь', 'площадь' => 'площадь', 'мкр' => 'микрорайон', 'микрорайон' => 'микрорайон',
         'тракт' => 'тракт', 'проезд' => 'проезд', 'пр-д' => 'проезд' }.freeze
  # «пр. Победителей, 141-61», «ул. Калиновского, 74/2-1Н»: после дефиса — номер помещения, дом — до него.
  # Длинные слова — раньше коротких и не посреди слова (22.10: «улица Монтажников» читалось как «ул.» + «ица Монтажников»)
  HOUSE = %r{(?:(?:,\s*|\s+(?=д\.|дом|\d+[а-яa-z]?(?:/\d+)?\s*(?:[,;.]|\z)))(?:д\.|дом)?\s*(\d+\s?[а-яa-z]?(?:/\d+)?)(?:-\S+)?(?:\s+кв\.?\s*\d+)?\.?)?\s*(?:[,;]|\z)}i
  STREET = %r{(?:\A|[\s,])(улица|ул|проспект|просп|пр-т|пр-д|пр|переулок|пер|бульвар|бул|б-р|шоссе|ш|площадь|пл|микрорайон|мкр|тракт|проезд)(?![а-я])\.?\s*([^,]+?)#{HOUSE}}i
  INIT = /(?<![А-Яа-я])[А-Я]\.\s*(?=[А-Я])/   # инициалы перед фамилией
  # тип после названия: «Центральная улица, 6», «2-ой Рабочий переулок, 12»
  STREET2 = %r{(?:\A|,)\s*([^,]+?)\s+(улица|переулок|проспект|бульвар|площадь|проезд|тракт|шоссе)#{HOUSE}}i
  # без типа: «г. Минск, Смоленская, 25» — слово с большой буквы сразу после пункта и номер дома
  BARE = /\A\s*,\s*([А-Я][А-Яа-я\-]+(?:\s[А-Я][А-Яа-я\-]+)?)\s*,\s*(?:д\.\s*)?(\d+[а-я]?(?:\/\d+)?)\s*(?:[,.]|\z)/

  # «д. Малые Аниковичи», «аг. Красная Воля»: в Obj::PLACE — только первое слово
  def town_of(a)
    m = a.match(Obj::PLACE) or return [a[/(?<![А-Яа-я])Минск(?![а-я])/] && 'Минск', nil]
    t = m[2]
    nx = a[m.end(0)..][/\A\s([А-Я][а-я]+)(?=\s*(?:,|\z))/, 1]
    t = "#{t} #{nx}" if nx && nx !~ /(?:ский|цкий|ской)\z/
    [t, m.end(0) + (nx ? nx.size + 1 : 0)]
  end

  def queries(addr)
    a = addr.to_s.tr('ё', 'е').tr('Ё', 'Е').gsub(/\b\d{6}\b,?/, '').strip
    town, at = town_of(a)
    dist = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+(?:р-н|район)/, 1]
    reg = a =~ /обл/ ? region_of(a) : nil   # «Минское шоссе» — не Минская область
    unless town
      # только сельсовет: «Узденский р-н, Слободской с/с, д. 8» — точка по сельсовету
      ss = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+с\/с/, 1]
      return ss && dist ? ["#{ss} сельский Совет, #{dist} район"] : []
    end
    rest = at ? a[at..] : a
    out = []
    street = num = nil
    if (s = rest.match(STREET))
      name = s[2].strip.gsub(INIT, '').sub(/\.\s.*\z/, '')   # «ул. Минское шоссе. УТП «БелшинаТранс»» → «Минское шоссе»
      street = name =~ /(?:шоссе|проспект|переулок|бульвар|тракт|проезд|площадь)\z/i ? name : "#{ST[s[1].downcase]} #{name}"
      num = s[3]&.delete(' ')
    elsif (s = rest.match(STREET2))
      street, num = "#{s[1].strip} #{s[2].downcase}", s[3]&.delete(' ')
    elsif (s = rest.match(BARE)) && s[1] !~ /(?:ский|цкий|ской)\z/
      street, num = s[1], s[2]
    end
    if street
      # инициалы: «ул. Ф.Скорины» → «улица Скорины», «ул. Пушкина А.С.» → «улица Пушкина»
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
    return 0 unless r   # 0 — сервис ответил «не нашёл»: запоминаем, чтобы не спрашивать снова
    # дом часто находится как организация в нём («Типография, ул. Урицкого, 19В») — это тоже точный адрес, если номер дома тот же
    num = q[/[\s,](\d+)[а-яa-z]?(?:\/\d+)?\z/i, 1]
    same = num && r.dig('address', 'house_number').to_s[/\A\d+/] == num
    # на той же улице: сервис отдаёт улицу как highway (secondary, residential…), а не road (22.10: такие считались «пунктом»),
    # или организацию на ней («ул. Академика Красина» → библиотека на «улице Красина»)
    words = q.split(',')[1].to_s.downcase.split.reject { |w| w.size < 3 || ST.value?(w) }
    on_street = !words.empty? && words.all? { |w| r.dig('address', 'road').to_s.downcase.include?(w) }
    prec = %w[building house].include?(r['addresstype']) || r['category'] == 'building' || same ? 'a' :
           r['addresstype'] == 'road' || r['category'] == 'highway' || on_street ? 's' : 'p'
    [r['lat'].to_f.round(5), r['lon'].to_f.round(5), prec]
  rescue JSON::ParserError
    nil   # сбой — не запоминаем
  end

  # область пункта не из списка районных центров (regions.rb): город или гп — среди городов с таким названием,
  # деревня — все тёзки должны быть в одной области, иначе 0 (лучше без области, чем чужая)
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

  # активные лоты без координат; stop — когда остановиться (общий бюджет прогона)
  def run(db, stat, stop)
    cache = File.exist?(CACHE) ? (JSON.parse(File.read(CACHE, encoding: 'UTF-8')) rescue {}) : {}
    asked = 0
    # и архив: лоты из архива площадок («г. п. Логишин») — тоже в фильтре «Регион»
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
    # V — разбор адреса поправлен (22.10): лоты, где на карте был только пункт или карты не было, ищем заново;
    # запросы с улицей — в кеше под новым ключом «2|…» (старые ответы считали улицу «пунктом»)
    todo = db.values.select { |l| l['status'] == 'active' && l['geo_try'].to_i < 2 &&
                                  (!l.key?('geo') || (l['geo_v'] != V && (l['geo'].nil? || l['geo'][2] == 'p'))) }
    todo.each do |l|
      break if asked >= CAP || Time.now > stop
      addr = l['platform'] == 'konfiskat.by' ? Obj.storage(Obj.rows_of(Store.details(l['key']))) : l['location']
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
        l.delete('geo_v')   # не досчитали — в следующий прогон
        l['geo_try'] = l['geo_try'].to_i + 1   # сервис не ответил или вышел лимит — попробуем в следующий раз
      else
        l['geo'] = nil   # сервис такого адреса не знает
        stat['на карте: адрес не найден'] += 1
      end
    end
    File.write(CACHE, JSON.generate(cache))
    STDERR.puts "карта: запросов к OpenStreetMap #{asked}, в кеше #{cache.size}"
  end
end
