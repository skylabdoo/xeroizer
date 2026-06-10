# frozen_string_literal: true

module Xeroizer
  module Record
    class Validator
      class InclusionOfValidator < Validator
        def valid?(record)
          return unless options[:in] && options[:in].is_a?(Array)
          return true if options[:allow_blanks] && record[attribute].blank?

          return if options[:in].include?(record[attribute])

          record.errors << [attribute, options[:message] || "not one of #{options[:in].join(', ')}"]
        end
      end
    end
  end
end
