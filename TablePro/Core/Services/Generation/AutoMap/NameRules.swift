//
//  NameRules.swift
//  TablePro
//

import Foundation

/// A window around the run's reference date, in days. Stored as an offset rather
/// than as literal dates so the rule table stays a constant; `AutoMapper` renders
/// it into the absolute bounds the date generators take.
struct AutoMapDateWindow: Sendable, Hashable {
    let fromDays: Int
    let toDays: Int
}

/// One name-based mapping. `acceptedTypes` is what makes the type beat the name:
/// a column called `email` typed `int` matches no rule and falls to the type tier.
struct NameRule {
    let pattern: NSRegularExpression
    let acceptedTypes: Set<TransferBaseType>
    let identifier: String
    let params: JSONValue
    let common: CommonParams
    let dateWindow: AutoMapDateWindow?
    let minimumColumnLength: Int?
    let warnsAboutGuessedValues: Bool

    init(
        _ pattern: String,
        _ acceptedTypes: Set<TransferBaseType>,
        _ identifier: String,
        params: JSONValue = .object([:]),
        common: CommonParams = .none,
        dateWindow: AutoMapDateWindow? = nil,
        minimumColumnLength: Int? = nil,
        warnsAboutGuessedValues: Bool = false
    ) {
        self.pattern = NameRules.compile(pattern)
        self.acceptedTypes = acceptedTypes
        self.identifier = identifier
        self.params = params
        self.common = common
        self.dateWindow = dateWindow
        self.minimumColumnLength = minimumColumnLength
        self.warnsAboutGuessedValues = warnsAboutGuessedValues
    }

    func accepts(_ column: GenerationColumn) -> Bool {
        guard acceptedTypes.contains(column.type.base) else { return false }
        guard let minimumColumnLength, let length = column.maxLength else { return true }
        return length >= minimumColumnLength
    }

    func matches(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..., in: candidate)
        return pattern.firstMatch(in: candidate, options: [], range: range) != nil
    }
}

/// The name tier of the auto-mapper. Rules are ordered and the first one whose
/// pattern matches a candidate name *and* whose accepted types include the
/// column's type wins.
///
/// Every regex is compiled once, when this table is first read. Recompiling per
/// column is the classic waste in a mapper this shape: a 300-column schema would
/// build the whole table 300 times.
enum NameRules {
    static let all: [NameRule] = booleanRules + dateRules + numberRules + stringRules + suffixRules

    /// Candidates are the outer loop so the column's own name outranks the form
    /// with the table prefix removed: `username` in table `users` is a username,
    /// not the `name` that the stripped form would match.
    static func firstMatch(for column: GenerationColumn, table: String) -> NameRule? {
        let candidates = ColumnNameNormalizer.candidates(column: column.name, table: table)
        for candidate in candidates {
            for rule in all where rule.accepts(column) && rule.matches(candidate) {
                return rule
            }
        }
        return nil
    }

    static func compile(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return NSRegularExpression()
        }
        return expression
    }

    private static let integers: Set<TransferBaseType> = [.int8, .int16, .int32, .int64]
    private static let decimals: Set<TransferBaseType> = [.decimal]
    private static let floats: Set<TransferBaseType> = [.float32, .float64]
    private static let strings: Set<TransferBaseType> = [.string, .text]
    private static let booleans: Set<TransferBaseType> = [.bool, .int8, .int16, .int32, .int64]
    private static let timestamps: Set<TransferBaseType> = [.timestamp, .timestampTZ]
    private static let days: Set<TransferBaseType> = [.date]

    private static let truthyNames = """
    ^(is_|has_|was_)?(active|enabled|available|visible|published|verified|approved|confirmed|paid\
    |completed|done|public|featured|read|subscribed)$
    """

    private static let falsyNames = """
    ^(is_|has_|was_)?(deleted|archived|banned|blocked|locked|disabled|hidden|cancelled|canceled\
    |expired|suspended|draft|refunded)$
    """

    private static let booleanPrefixes = """
    ^(is|has|can|should|was|were|allow|allows|enable|enables|use|uses|do|does|did|must|need|needs\
    |require|requires)_[a-z0-9_]+$
    """

    private static let booleanRules: [NameRule] = [
        NameRule(truthyNames, booleans, BooleanGenerator.identifier, params: .object(["truePercent": .int(80)])),
        NameRule(falsyNames, booleans, BooleanGenerator.identifier, params: .object(["truePercent": .int(10)])),
        NameRule(booleanPrefixes, booleans, BooleanGenerator.identifier, params: .object(["truePercent": .int(50)]))
    ]

    private static let createdNames = """
    ^(created|createdat|createdon|createdtime|createtime|createdate|inserted|insertedat|registered\
    |registeredat|joined|joinedat|signedup|signedupat|added|addedat)$
    """

    private static let updatedNames = """
    ^(updated|updatedat|updatedon|updatetime|updatedtime|modified|modifiedat|modifiedon|lastmodified\
    |changed|changedat|edited|editedat|touchedat)$
    """

    private static let removedNames = """
    ^(deleted|deletedat|deletedon|removedat|cancelledat|canceledat|archivedat|voidedat)$
    """

    private static let birthNames = "^(birthday|birthdate|dateofbirth|dob|birth)$"

    private static let expiryNames = """
    ^(expiresat|expiredat|expiryat|expirydate|expireat|expireson|validuntil|validto|dueat|duedate\
    |deadline)$
    """

    private static let startNames = """
    ^(startdate|startsat|startat|startedat|startson|begindate|beginsat|validfrom|effectivedate)$
    """

    private static let endNames = "^(enddate|endsat|endat|endedat|endson|finishdate|finishedat|closedat)$"

    private static let lastSeenNames = """
    ^(lastlogin|lastloginat|lastseen|lastseenat|lastactiveat|lastusedat|lastvisitat)$
    """

    private static let dateRules: [NameRule] = [
        NameRule(
            createdNames,
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -730, toDays: 0)
        ),
        NameRule(
            createdNames,
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -730, toDays: 0)
        ),
        NameRule(
            updatedNames,
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -30, toDays: 0)
        ),
        NameRule(
            updatedNames,
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -30, toDays: 0)
        ),
        NameRule(
            removedNames,
            timestamps,
            DateTimeGenerator.identifier,
            common: CommonParams(nullPercent: 90),
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        ),
        NameRule(
            removedNames,
            days,
            DateGenerator.identifier,
            common: CommonParams(nullPercent: 90),
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        ),
        NameRule(
            birthNames,
            days,
            DateGenerator.identifier,
            params: .object(["from": .string("1950-01-01"), "to": .string("2005-12-31")])
        ),
        NameRule(
            birthNames,
            timestamps,
            DateTimeGenerator.identifier,
            params: .object([
                "from": .string("1950-01-01T00:00:00Z"),
                "to": .string("2005-12-31T23:59:59Z")
            ])
        ),
        NameRule(
            expiryNames,
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: 0, toDays: 730)
        ),
        NameRule(
            expiryNames,
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: 0, toDays: 730)
        ),
        NameRule(
            startNames,
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        ),
        NameRule(
            startNames,
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        ),
        NameRule(
            endNames,
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: 0, toDays: 365)
        ),
        NameRule(
            endNames,
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: 0, toDays: 365)
        ),
        NameRule(
            lastSeenNames,
            timestamps,
            DateTimeGenerator.identifier,
            common: CommonParams(nullPercent: 20),
            dateWindow: AutoMapDateWindow(fromDays: -90, toDays: 0)
        )
    ]

    private static let moneyNames = """
    ^(price|amount|cost|total|subtotal|grandtotal|fee|balance|salary|revenue|payment|charge|unitprice\
    |totalprice|totalamount|paidamount)$
    """

    private static let rateNames = "^(discount|tax|taxamount|shipping|shippingfee|vat)$"

    private static let percentNames = "^(percent|percentage|discountpercent|completionpercent)$"

    private static let orderingNames = """
    ^(sortorder|displayorder|position|sequence|priority|ordering|rank|level|depth|step)$
    """

    private static let countNames = "^(qty|quantity|count|stock|inventory|units|itemcount)$"

    private static func bounds(_ minimum: JSONValue, _ maximum: JSONValue) -> JSONValue {
        .object(["min": minimum, "max": maximum])
    }

    private static let numberRules: [NameRule] = [
        NameRule("^(age)$", integers, IntegerGenerator.identifier, params: bounds(.int(18), .int(80))),
        NameRule(countNames, integers, IntegerGenerator.identifier, params: bounds(.int(1), .int(100))),
        NameRule("^(rating|stars|starcount)$", integers, IntegerGenerator.identifier, params: bounds(.int(1), .int(5))),
        NameRule("^(score|points|karma)$", integers, IntegerGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule(percentNames, integers, IntegerGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule(percentNames, decimals, DecimalGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule(percentNames, floats, DoubleGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule("^(year|birthyear)$", integers, IntegerGenerator.identifier, params: bounds(.int(1_970), .int(2_030))),
        NameRule("^(month)$", integers, IntegerGenerator.identifier, params: bounds(.int(1), .int(12))),
        NameRule(orderingNames, integers, IntegerGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule("^(lat|latitude)$", decimals, DecimalGenerator.identifier, params: bounds(.int(-90), .int(90))),
        NameRule("^(lat|latitude)$", floats, DoubleGenerator.identifier, params: bounds(.int(-90), .int(90))),
        NameRule(
            "^(lng|lon|long|longitude)$",
            decimals,
            DecimalGenerator.identifier,
            params: bounds(.int(-180), .int(180))
        ),
        NameRule(
            "^(lng|lon|long|longitude)$",
            floats,
            DoubleGenerator.identifier,
            params: bounds(.int(-180), .int(180))
        ),
        NameRule(moneyNames, decimals, DecimalGenerator.identifier, params: bounds(.int(0), .int(10_000))),
        NameRule(moneyNames, floats, DoubleGenerator.identifier, params: bounds(.int(0), .int(10_000))),
        NameRule(moneyNames, integers, IntegerGenerator.identifier, params: bounds(.int(0), .int(10_000))),
        NameRule(rateNames, decimals, DecimalGenerator.identifier, params: bounds(.int(0), .int(100))),
        NameRule(rateNames, floats, DoubleGenerator.identifier, params: bounds(.int(0), .int(100)))
    ]

    private static func randomString(
        _ charset: RandomStringCharset,
        _ minimum: Int,
        _ maximum: Int,
        custom: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "minLength": .int(minimum),
            "maxLength": .int(maximum),
            "charset": .string(charset.rawValue)
        ]
        if let custom { params["customCharacters"] = .string(custom) }
        return .object(params)
    }

    private static func loremWords(_ minimum: Int, _ maximum: Int) -> JSONValue {
        .object(["minWords": .int(minimum), "maxWords": .int(maximum), "capitalize": .bool(true)])
    }

    private static func list(_ values: [String]) -> JSONValue {
        .object(["values": .array(values.map(JSONValue.string))])
    }

    private static let uppercaseAlphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    private static let emailNames = "^(email|emailaddress|mail|contactemail|primaryemail)$"

    private static let usernameNames = "^(username|login|handle|nickname|nick|screenname|account|accountname)$"

    private static let secretNames = """
    ^(password|passwd|pwd|passwordhash|hashedpassword|encryptedpassword|token|apikey|accesstoken\
    |refreshtoken|secret|salt|hash|checksum|signature|sessionid|nonce)$
    """

    private static let phoneNames = """
    ^(phone|phonenumber|tel|telephone|mobile|mobilenumber|mobilephone|cellphone|cell|fax|whatsapp\
    |zalo|contactnumber)$
    """

    private static let titleNames = """
    ^(fullname|name|displayname|contactname|customername|productname|title|subject|headline|label\
    |jobtitle|department|brand)$
    """

    private static let companyNames = "^(companyname|company|organization|organisation|org|employer|vendor|supplier)$"

    private static let addressNames = """
    ^(address|address1|address2|addressline1|addressline2|addr|street|streetaddress|streetname)$
    """

    private static let longTextNames = """
    ^(description|desc|content|body|note|notes|remark|remarks|bio|about|details|instructions\
    |introduction|overview)$
    """

    private static let shortTextNames = """
    ^(comment|comments|summary|excerpt|message|reason|feedback|review|shortdescription)$
    """

    private static let codeNames = """
    ^(code|sku|barcode|ean|upc|reference|referenceno|refno|serial|serialnumber|invoiceno\
    |invoicenumber|ordernumber|ordercode|couponcode|promocode|voucher)$
    """

    private static let mediaNames = """
    ^(avatar|avatarurl|imageurl|photourl|thumbnail|thumbnailurl|image|photo|picture|logo|logourl\
    |banner|cover|coverimage|attachment)$
    """

    private static let stringRules: [NameRule] = [
        NameRule(
            emailNames,
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 12),
            common: CommonParams(suffix: "@example.com")
        ),
        NameRule(usernameNames, strings, RandomStringGenerator.identifier, params: randomString(.lowercase, 6, 12)),
        NameRule(secretNames, strings, RandomStringGenerator.identifier, params: randomString(.hexadecimal, 32, 64)),
        NameRule(phoneNames, strings, RandomStringGenerator.identifier, params: randomString(.numeric, 9, 10)),
        NameRule(
            "^(firstname|fname|givenname|forename)$",
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(1, 1)
        ),
        NameRule(
            "^(lastname|lname|surname|familyname)$",
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(1, 1)
        ),
        NameRule("^(middlename|middleinitial)$", strings, LoremWordsGenerator.identifier, params: loremWords(1, 1)),
        NameRule(titleNames, strings, LoremWordsGenerator.identifier, params: loremWords(2, 3)),
        NameRule(
            companyNames,
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(2, 2),
            common: CommonParams(suffix: " Inc.")
        ),
        NameRule(
            "^(city|town|district|ward|village)$",
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(1, 2)
        ),
        NameRule(
            "^(province|region|county|prefecture)$",
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(1, 1)
        ),
        NameRule(
            "^(country|nation|countryname)$",
            strings,
            ListGenerator.identifier,
            params: list(["United States", "Vietnam", "Japan", "Germany", "France", "United Kingdom"])
        ),
        NameRule(
            "^(countrycode|iso2|isocode|countryiso)$",
            strings,
            ListGenerator.identifier,
            params: list(["US", "VN", "JP", "DE", "FR", "GB"])
        ),
        NameRule(addressNames, strings, LoremWordsGenerator.identifier, params: loremWords(3, 4)),
        NameRule(
            "^(zip|zipcode|postalcode|postcode)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.numeric, 5, 5)
        ),
        NameRule(
            longTextNames,
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(8, 40),
            minimumColumnLength: 40
        ),
        NameRule(
            shortTextNames,
            strings,
            LoremWordsGenerator.identifier,
            params: loremWords(5, 15),
            minimumColumnLength: 20
        ),
        NameRule(
            "^(slug|permalink|alias|urlkey|seourl)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 8, 24)
        ),
        NameRule(
            codeNames,
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.custom, 8, 12, custom: uppercaseAlphanumeric)
        ),
        NameRule(
            "^(url|website|websiteurl|homepage|link|href|webpage)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 10),
            common: CommonParams(prefix: "https://", suffix: ".example.com")
        ),
        NameRule(
            mediaNames,
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 12),
            common: CommonParams(prefix: "https://example.com/", suffix: ".png")
        ),
        NameRule(
            "^(filename|file)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 12),
            common: CommonParams(suffix: ".pdf")
        ),
        NameRule(
            "^(mimetype|contenttype|filetype)$",
            strings,
            ListGenerator.identifier,
            params: list(["image/png", "image/jpeg", "application/pdf", "text/plain"])
        ),
        NameRule("^(gender|sex)$", strings, ListGenerator.identifier, params: list(["male", "female", "other"])),
        NameRule(
            "^(currency|currencycode)$",
            strings,
            ListGenerator.identifier,
            params: list(["USD", "EUR", "VND", "JPY", "GBP"])
        ),
        NameRule(
            "^(locale|language|lang|languagecode|localecode)$",
            strings,
            ListGenerator.identifier,
            params: list(["en_US", "vi_VN", "ja_JP", "de_DE"])
        ),
        NameRule(
            "^(timezone|tz|timezonename)$",
            strings,
            ListGenerator.identifier,
            params: list(["UTC", "Asia/Ho_Chi_Minh", "America/New_York", "Europe/London"])
        ),
        NameRule(
            "^(color|colour|colorcode|hexcolor)$",
            strings,
            ListGenerator.identifier,
            params: list(["#FF5733", "#33FF57", "#3357FF", "#F1C40F", "#9B59B6"])
        ),
        NameRule(
            "^(version|appversion|semver)$",
            strings,
            ListGenerator.identifier,
            params: list(["1.0.0", "1.1.0", "1.2.3", "2.0.0"])
        ),
        NameRule(
            "^(status|state|stage|phase)$",
            strings,
            ListGenerator.identifier,
            params: list(["active", "inactive", "pending"]),
            warnsAboutGuessedValues: true
        ),
        NameRule("^(uuid|guid|externalid|publicid|uid)$", strings.union([.uuid]), UuidGenerator.identifier)
    ]

    /// Suffix rules, matched against the tokenized name so the boundary is a real
    /// one: `proof_url` is a URL, `casino` is not a number. They run last, after
    /// every exact rule above has had its turn, and they are what stops a real
    /// schema's `*_serial`, `*_hash` and `*_id` columns from all reading as prose.
    private static let suffixRules: [NameRule] = [
        NameRule(
            "_(url|uri|link)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 10),
            common: CommonParams(prefix: "https://", suffix: ".example.com")
        ),
        NameRule(
            "_(hash|token|secret|signature|apikey|salt)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.hexadecimal, 32, 64)
        ),
        NameRule(
            "_(serial|serialno|code|number|no|sku|barcode|reference)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.custom, 8, 12, custom: uppercaseAlphanumeric)
        ),
        NameRule(
            "_(email|mail)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 12),
            common: CommonParams(suffix: "@example.com")
        ),
        NameRule(
            "_(username|login|nickname)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.lowercase, 6, 12)
        ),
        NameRule(
            "_(phone|phonenumber|mobile|tel|fax)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.numeric, 9, 10)
        ),
        NameRule(
            "_(id|uid)$",
            strings,
            RandomStringGenerator.identifier,
            params: randomString(.alphanumeric, 12, 24)
        ),
        NameRule(
            "_(percent|percentage)$",
            integers,
            IntegerGenerator.identifier,
            params: bounds(.int(0), .int(100))
        ),
        NameRule(
            "_(rate|ratio|percent|percentage)$",
            decimals,
            DecimalGenerator.identifier,
            params: bounds(.int(0), .int(1))
        ),
        NameRule(
            "_(rate|ratio)$",
            floats,
            DoubleGenerator.identifier,
            params: bounds(.int(0), .int(1))
        ),
        NameRule(
            "_(at|on|time|date)$",
            timestamps,
            DateTimeGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        ),
        NameRule(
            "_(at|on|time|date)$",
            days,
            DateGenerator.identifier,
            dateWindow: AutoMapDateWindow(fromDays: -365, toDays: 0)
        )
    ]
}
