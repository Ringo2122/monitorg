# encoding: utf-8
#
# Марка легковых, грузовых, автобусов и микроавтобусов — для фильтра каталога (21.10.2026).
# Сначала поле «Марка» карточки площадки, потом название лота. Разное написание одной марки сводим к одному
# названию (МАZ, MAZ, МАЗ → МАЗ; Cherry → Chery). Не нашли в словаре или марки нет — «Другие» (решение Артёма).
module Brands
  module_function

  OTHER = 'Другие'

  # название в фильтре → как пишут площадки (по строке в нижнем регистре, латиница и кириллица)
  LIST = {
    'Alfa Romeo' => /alfa\s*romeo/, 'Audi' => /\baudi\b|\bауди\b/, 'BAIC' => /\bbaic\b/, 'Belgee' => /belgee/,
    'BMW' => /\bbmw\b|\bбмв\b/, 'BYD' => /\bbyd\b/, 'Cadillac' => /cadillac/, 'Changan' => /changan/, 'Chery' => /\bcherr?y\b|\bчери\b/,
    'Chevrolet' => /chevrolet|шевроле/, 'Chrysler' => /chrysler|крайслер/, 'Citroen' => /citro[eë]n|ситро[её]н/, 'Dacia' => /\bdacia\b/,
    'DAF' => /\bdaf\b/, 'Daewoo' => /daewoo|\bдэу\b/, 'Dodge' => /\bdodge\b/, 'Dongfeng' => /dongfen[gf]/, 'Exeed' => /\bexeed\b/,
    'FAW' => /\bfaw\b/, 'Fiat' => /\bfiat\b|\bфиат\b/, 'Ford' => /\bford\b|\bфорд\b/, 'Forthing' => /forthing/, 'Foton' => /\bfoton\b/,
    'Geely' => /geely|\bджили\b/, 'Great Wall' => /great\s*wall/, 'Haval' => /\bhaval\b/, 'Honda' => /\bhonda\b|\bхонда\b/,
    'Howo' => /\bhowo\b|sinotruk/, 'Hyundai' => /hyundai|хендай|хундай/, 'Infiniti' => /infiniti/, 'Isuzu' => /isuzu|исузу/,
    'Iveco' => /iveco|ивеко/, 'JAC' => /\bjac\b/, 'Jaguar' => /jaguar/, 'Jeep' => /\bjeep\b/, 'Kia' => /\bkia\b|\bкиа\b/,
    'Lancia' => /lancia/, 'Land Rover' => /land\s*rover|range\s*rover/, 'Lexus' => /lexus|лексус/, 'Lifan' => /\blifan\b/,
    'MAN' => /\bman\b/, 'Mazda' => /mazda|мазда/, 'McLaren' => /mclaren/, 'Mercedes-Benz' => /mercedes|mepsedes|мерседес/,
    'Mitsubishi' => /mitsubishi|мицубиси/, 'Nissan' => /nissan|ниссан/, 'Opel' => /\bopel\b|\bопель\b/, 'Peugeot' => /peugeot|пежо/,
    'Plymouth' => /plymouth/, 'Pontiac' => /pontiac/, 'Porsche' => /porsche|порше/, 'Ravon' => /\bravon\b/, 'Renault' => /renault|\bрено\b/,
    'Roewe' => /\broewe\b/, 'Rover' => /(?<!land )\brover\b/, 'Saipa' => /\bsaipa\b/, 'Samand' => /samand|саманд/, 'Scania' => /scania|скания/,
    'Seat' => /\bseat\b/, 'Skoda' => /skoda|шкода/, 'SsangYong' => /ssang\s*yong/, 'Subaru' => /subaru|субару/, 'Suzuki' => /suzuki|сузуки/,
    'Tesla' => /\btesla\b/, 'Toyota' => /toyota|тойота/, 'Volkswagen' => /volkswagen|\bvw\b|фольксваген/, 'Volvo' => /volvo|вольво/,
    'Yutong' => /yutong/, 'Zeekr' => /zeekr/,
    'Lada (ВАЗ)' => /\blada\b|\bлада\b|\bваз\b|\bvaz\b/, 'ГАЗ' => /\bгаз\b|\bgaz\b|газель|gazelle|\bсоболь\b/,
    'ЗАЗ' => /\bзаз\b|\bzaz\b/, 'ЗИЛ' => /\bзил\b|\bzil\b/, 'ИЖ' => /\bиж\b/, 'КамАЗ' => /камаз|kamaz/, 'МАЗ' => /\bмаз\b|\bmaz\b/,
    'МЗКТ' => /\bмзкт\b|\bmzkt\b/, 'Москвич' => /москвич|moskvich|\bазлк\b/, 'Неман' => /\bнеман\b/, 'ПАЗ' => /\bпаз\b|\bpaz\b/,
    'БелАЗ' => /белаз|belaz/, 'Богдан' => /bogdan|богдан/, 'КАвЗ' => /\bкавз\b|\bkavz\b/, 'УАЗ' => /\bуаз\b|\buaz\b/, 'Урал' => /\bурал\b/
  }.freeze

  # Буквы-двойники: в слове, где перемешаны латиница и кириллица («МАZ»), кириллицу пишем латиницей
  LOOK = { 'а' => 'a', 'в' => 'b', 'е' => 'e', 'к' => 'k', 'м' => 'm', 'н' => 'h', 'о' => 'o', 'р' => 'p', 'с' => 'c', 'т' => 't', 'х' => 'x' }.freeze

  def norm(s)
    s.to_s.downcase.split(/(\s+)/).map { |w| w =~ /[a-z]/ && w =~ /[а-яё]/ ? w.gsub(/[авекмнорстх]/, LOOK) : w }.join
  end

  def find(s)
    t = norm(s)
    return nil if t.strip.empty?
    LIST.find { |_, re| t =~ re }&.first
  end

  # lot — лот, rows — строки подробностей [[название, значение], …]
  def of(lot, rows)
    mark = (rows.find { |k, _| k.to_s.strip =~ /\AМарка/ } || [])[1]
    find(mark) || find(lot['name']) || OTHER
  end
end
