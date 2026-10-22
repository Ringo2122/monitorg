# encoding: utf-8
module Area
  module_function

  NUM = '(\d{1,3}(?:[  ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)'
  M2 = '(?:кв\.?\s*м(?:етр[а-я]*)?\.?|м²|м2|м\.\s*кв)'
  TOTAL = /общ(?:[а-я]*\s+|\.\s*)(?:площад[а-я]*|пл\.)(?:\s+(?!застро|участ)[а-я]+){0,3}?(?:\s*\([^)]{0,30}\))?\s*(?:[-:–—]|составляет|равна)?\s*#{NUM}(?!\s*га\b)(?![.,]?\d)/i
  ANY = /#{NUM}\s*#{M2}|площад[а-я]*\s*[-:–—]\s*#{NUM}(?!\s*га\b)(?![.,]?\d)/i
  HA = /площад[а-я]*\s*(?:,\s*га\s*)?(?:[-:–—]\s*)?#{NUM}\s*(?:га\b)?/i
  NOT = /(?:участ[а-я]*|застройки|жил[а-я]*)\s*(?:[^\s.;]+\s*){0,3}\z|\bза\s*\z/i

  def num(s) s.to_s.gsub(/[  ]/, '').tr(',', '.').to_f end

  def grab(t, re)
    vals = []
    t.scan(re) do
      m = Regexp.last_match
      next if m.pre_match[-60..].to_s =~ NOT
      v = num(m.captures.compact.first)
      vals << v if v >= 1 && v < 1_000_000
    end
    vals.uniq
  end

  def of(text, land: false)
    t = text.to_s.gsub(/\s+/, ' ')
    unless land
      vals = grab(t, TOTAL)
      vals = grab(t, ANY) if vals.empty?
      return vals.sum.round(1) if vals.any?
      return nil
    end
    (m = t.match(/#{HA.source}/i)) && m[0] =~ /га/ && (v = num(m[1])).positive? && v < 10_000 ? (v * 10_000).round : nil
  end
end
