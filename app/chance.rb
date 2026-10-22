# encoding: utf-8
module Chance
  module_function

  MIN  = 30
  DAYS = 365

  def band(p)
    p < 1e3 ? 0 : p < 5e3 ? 1 : p < 2e4 ? 2 : p < 1e5 ? 3 : 4
  end

  def keys(l, price)
    s = l['section']
    sub = l['sub_ru'] || '-'
    b = band(price.to_f)
    ["#{s}|#{sub}|#{l['platform']}|#{b}", "#{s}|#{sub}|#{l['platform']}", "#{s}|#{sub}|#{b}", "#{s}|#{sub}", s]
  end

  def apply(lots, now)
    cnt = Hash.new { |h, k| h[k] = [0, 0] }
    lots.each do |l|
      r = l['result']
      next unless r.is_a?(Hash) && %w[sold single failed].include?(r['st']) && r['at'].to_i > now - DAYS * 86_400
      keys(l, r['start'] || l['price']).each do |k|
        cnt[k][0] += 1
        cnt[k][1] += 1 unless r['st'] == 'failed'
      end
    end
    lots.each do |l|
      next unless l['status'] == 'active'
      k = keys(l, l['price']).find { |x| cnt[x][0] >= MIN } or next
      n, y = cnt[k]
      l['chance'] = [(y * 100.0 / n).round, n]
    end
  end
end
