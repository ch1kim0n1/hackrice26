import Foundation

/// Product data returned by the Open Food Facts / Open Products Facts APIs (v2).
/// All fields are decoded tolerantly: the API mixes numbers/strings and omits
/// fields freely, so a single missing or mistyped field must not kill the decode.
public struct FoodProduct: Codable {
    public let productName: String?
    public let productNameEn: String?
    public let genericName: String?
    public let brands: String?
    public let quantity: String?
    public let productQuantity: Double?
    public let servingSize: String?
    public let servingQuantity: Double?
    public let categories: String?
    public let origins: String?
    public let manufacturingPlaces: String?
    public let stores: String?
    public let countries: String?
    public let packaging: String?
    public let packagingText: String?
    public let packagingTags: [String]?
    public let labelsTags: [String]?
    public let allergensTags: [String]?
    public let additivesTags: [String]?
    public let vitaminsTags: [String]?
    public let mineralsTags: [String]?
    public let ingredientsText: String?
    public let ingredientsTextEn: String?
    public let ingredients: [IngredientItem]?
    public let ingredientsAnalysisTags: [String]?
    public let nutrientLevels: [String: String]?
    public let novaGroup: Int?
    public let ecoscoreGrade: String?
    public let ecoscoreScore: Double?
    public let nutriscoreGrade: String?
    public let conservationConditions: String?
    public let otherInformation: String?
    public let warning: String?
    public let customerService: String?
    public let imageFrontUrl: String?
    public let imageUrl: String?
    public let imageIngredientsUrl: String?
    public let imageNutritionUrl: String?
    public let imagePackagingUrl: String?
    public let nutriments: Nutriments?

    public var displayName: String {
        productNameEn ?? productName ?? genericName ?? "Unknown product"
    }

    public var ingredientsSummary: String? {
        ingredientsTextEn ?? ingredientsText
    }

    public enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productNameEn = "product_name_en"
        case genericName = "generic_name"
        case brands
        case quantity
        case productQuantity = "product_quantity"
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case categories
        case origins
        case manufacturingPlaces = "manufacturing_places"
        case stores
        case countries
        case packaging
        case packagingText = "packaging_text"
        case packagingTags = "packaging_tags"
        case labelsTags = "labels_tags"
        case allergensTags = "allergens_tags"
        case additivesTags = "additives_tags"
        case vitaminsTags = "vitamins_tags"
        case mineralsTags = "minerals_tags"
        case ingredientsText = "ingredients_text"
        case ingredientsTextEn = "ingredients_text_en"
        case ingredients
        case ingredientsAnalysisTags = "ingredients_analysis_tags"
        case nutrientLevels = "nutrient_levels"
        case novaGroup = "nova_group"
        case ecoscoreGrade = "ecoscore_grade"
        case ecoscoreScore = "ecoscore_score"
        case nutriscoreGrade = "nutriscore_grade"
        case conservationConditions = "conservation_conditions"
        case otherInformation = "other_information"
        case warning
        case customerService = "customer_service"
        case imageFrontUrl = "image_front_url"
        case imageUrl = "image_url"
        case imageIngredientsUrl = "image_ingredients_url"
        case imageNutritionUrl = "image_nutrition_url"
        case imagePackagingUrl = "image_packaging_url"
        case nutriments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productName = Self.str(c, .productName)
        productNameEn = Self.str(c, .productNameEn)
        genericName = Self.str(c, .genericName)
        brands = Self.str(c, .brands)
        quantity = Self.str(c, .quantity)
        productQuantity = Self.dbl(c, .productQuantity)
        servingSize = Self.str(c, .servingSize)
        servingQuantity = Self.dbl(c, .servingQuantity)
        categories = Self.str(c, .categories)
        origins = Self.str(c, .origins)
        manufacturingPlaces = Self.str(c, .manufacturingPlaces)
        stores = Self.str(c, .stores)
        countries = Self.str(c, .countries)
        packaging = Self.str(c, .packaging)
        packagingText = Self.str(c, .packagingText)
        packagingTags = Self.strArray(c, .packagingTags)
        labelsTags = Self.strArray(c, .labelsTags)
        allergensTags = Self.strArray(c, .allergensTags)
        additivesTags = Self.strArray(c, .additivesTags)
        vitaminsTags = Self.strArray(c, .vitaminsTags)
        mineralsTags = Self.strArray(c, .mineralsTags)
        ingredientsText = Self.str(c, .ingredientsText)
        ingredientsTextEn = Self.str(c, .ingredientsTextEn)
        ingredients = try? c.decode([IngredientItem].self, forKey: .ingredients)
        ingredientsAnalysisTags = Self.strArray(c, .ingredientsAnalysisTags)
        nutrientLevels = try? c.decode([String: String].self, forKey: .nutrientLevels)
        novaGroup = Self.dbl(c, .novaGroup).map { Int($0) }
        ecoscoreGrade = Self.str(c, .ecoscoreGrade)
        ecoscoreScore = Self.dbl(c, .ecoscoreScore)
        nutriscoreGrade = Self.str(c, .nutriscoreGrade)
        conservationConditions = Self.str(c, .conservationConditions)
        otherInformation = Self.str(c, .otherInformation)
        warning = Self.str(c, .warning)
        customerService = Self.str(c, .customerService)
        imageFrontUrl = Self.str(c, .imageFrontUrl)
        imageUrl = Self.str(c, .imageUrl)
        imageIngredientsUrl = Self.str(c, .imageIngredientsUrl)
        imageNutritionUrl = Self.str(c, .imageNutritionUrl)
        imagePackagingUrl = Self.str(c, .imagePackagingUrl)
        nutriments = try? c.decode(Nutriments.self, forKey: .nutriments)
    }

    // MARK: Tolerant decode helpers

    private static func str(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        try? c.decode(String.self, forKey: key)
    }

    private static func dbl(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
        return nil
    }

    private static func strArray(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String]? {
        try? c.decode([String].self, forKey: key)
    }
}

/// A single structured ingredient entry (name, optional percent, dietary flags).
public struct IngredientItem: Codable {
    public let text: String?
    public let percent: Double?
    public let vegan: String?
    public let vegetarian: String?

    public enum CodingKeys: String, CodingKey {
        case text
        case percent
        case vegan
        case vegetarian
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decode(String.self, forKey: .text)
        if let d = try? c.decode(Double.self, forKey: .percent) {
            percent = d
        } else if let s = try? c.decode(String.self, forKey: .percent) {
            percent = Double(s)
        } else {
            percent = nil
        }
        vegan = try? c.decode(String.self, forKey: .vegan)
        vegetarian = try? c.decode(String.self, forKey: .vegetarian)
    }
}

public struct OFFResponse: Codable {
    public let status: Int?
    public let product: FoodProduct?
}

/// Nutrition facts per 100 g / 100 ml. Values are decoded tolerantly because the
/// API sometimes returns numbers as strings.
public struct Nutriments: Codable {
    public let energyKcal100g: Double?
    public let fat100g: Double?
    public let saturatedFat100g: Double?
    public let carbohydrates100g: Double?
    public let sugars100g: Double?
    public let fiber100g: Double?
    public let proteins100g: Double?
    public let salt100g: Double?
    public let sodium100g: Double?

    public enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g"
        case fat100g = "fat_100g"
        case saturatedFat100g = "saturated-fat_100g"
        case carbohydrates100g = "carbohydrates_100g"
        case sugars100g = "sugars_100g"
        case fiber100g = "fiber_100g"
        case proteins100g = "proteins_100g"
        case salt100g = "salt_100g"
        case sodium100g = "sodium_100g"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        energyKcal100g = Self.tolerantDouble(c, .energyKcal100g)
        fat100g = Self.tolerantDouble(c, .fat100g)
        saturatedFat100g = Self.tolerantDouble(c, .saturatedFat100g)
        carbohydrates100g = Self.tolerantDouble(c, .carbohydrates100g)
        sugars100g = Self.tolerantDouble(c, .sugars100g)
        fiber100g = Self.tolerantDouble(c, .fiber100g)
        proteins100g = Self.tolerantDouble(c, .proteins100g)
        salt100g = Self.tolerantDouble(c, .salt100g)
        sodium100g = Self.tolerantDouble(c, .sodium100g)
    }

    private static func tolerantDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
        return nil
    }
}
