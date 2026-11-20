//
// ObjectVocabularyTable.swift
//
// DATA ONLY: one row per object the bundled yolo11n detector knows, in the
// model's own class order. Columns: detector label, French, Chinese
// (Mandarin, Simplified), pinyin, Spanish (Spain).
//
// !! WRITTEN BY THE BUILDER, NOT YET REVIEWED BY A NATIVE SPEAKER. !!
// This file is kept free of logic so it can be handed to one as-is.
//
// Rules the rows follow:
//  - The label means what the COCO dataset means: "mouse" is the computer
//    mouse, "orange" the fruit, "remote" the TV remote, "tie" the necktie.
//  - Bare nouns, no articles ("banane", not "la banane").
//  - Where a label covers several things, the generic word ("cup" ->
//    tasse). Where NO single word is safe, `nil` = stay silent rather than
//    guess: "sink" is évier/fregadero in a kitchen but lavabo in a
//    bathroom, and the detector cannot tell which.
//  - `en:` overrides the spoken English only where the label is an
//    abbreviation or an odd spelling ("tv", "hair drier").
//
// tests/translate/ pins that all 80 labels are present and that every
// cell is either a word or a deliberate nil.
//

import Foundation

enum ObjectVocabularyTable {
    struct Row {
        let label: String
        let english: String
        let fr: String?
        let zh: String?
        let pinyin: String?
        let es: String?

        init(_ label: String, en: String? = nil,
             fr: String?, zh: String?, pinyin: String?, es: String?) {
            self.label = label
            self.english = en ?? label
            self.fr = fr
            self.zh = zh
            self.pinyin = pinyin
            self.es = es
        }
    }

    static let rows: [Row] = [
        Row("person", fr: "personne", zh: "人", pinyin: "rén", es: "persona"),
        Row("bicycle", fr: "vélo", zh: "自行车", pinyin: "zìxíngchē", es: "bicicleta"),
        Row("car", fr: "voiture", zh: "汽车", pinyin: "qìchē", es: "coche"),
        Row("motorcycle", fr: "moto", zh: "摩托车", pinyin: "mótuōchē", es: "moto"),
        Row("airplane", fr: "avion", zh: "飞机", pinyin: "fēijī", es: "avión"),
        Row("bus", fr: "bus", zh: "公交车", pinyin: "gōngjiāochē", es: "autobús"),
        Row("train", fr: "train", zh: "火车", pinyin: "huǒchē", es: "tren"),
        Row("truck", fr: "camion", zh: "卡车", pinyin: "kǎchē", es: "camión"),
        Row("boat", fr: "bateau", zh: "船", pinyin: "chuán", es: "barco"),
        Row("traffic light", fr: "feu tricolore", zh: "红绿灯", pinyin: "hónglǜdēng", es: "semáforo"),
        Row("fire hydrant", fr: "bouche d'incendie", zh: "消防栓", pinyin: "xiāofángshuān", es: "boca de incendios"),
        Row("stop sign", fr: "panneau stop", zh: "停车标志", pinyin: "tíngchē biāozhì", es: "señal de stop"),
        Row("parking meter", fr: "parcmètre", zh: "停车计时器", pinyin: "tíngchē jìshíqì", es: "parquímetro"),
        Row("bench", fr: "banc", zh: "长椅", pinyin: "chángyǐ", es: "banco"),
        Row("bird", fr: "oiseau", zh: "鸟", pinyin: "niǎo", es: "pájaro"),
        Row("cat", fr: "chat", zh: "猫", pinyin: "māo", es: "gato"),
        Row("dog", fr: "chien", zh: "狗", pinyin: "gǒu", es: "perro"),
        Row("horse", fr: "cheval", zh: "马", pinyin: "mǎ", es: "caballo"),
        Row("sheep", fr: "mouton", zh: "羊", pinyin: "yáng", es: "oveja"),
        Row("cow", fr: "vache", zh: "牛", pinyin: "niú", es: "vaca"),
        Row("elephant", fr: "éléphant", zh: "大象", pinyin: "dàxiàng", es: "elefante"),
        Row("bear", fr: "ours", zh: "熊", pinyin: "xióng", es: "oso"),
        Row("zebra", fr: "zèbre", zh: "斑马", pinyin: "bānmǎ", es: "cebra"),
        Row("giraffe", fr: "girafe", zh: "长颈鹿", pinyin: "chángjǐnglù", es: "jirafa"),
        Row("backpack", fr: "sac à dos", zh: "背包", pinyin: "bēibāo", es: "mochila"),
        Row("umbrella", fr: "parapluie", zh: "雨伞", pinyin: "yǔsǎn", es: "paraguas"),
        Row("handbag", fr: "sac à main", zh: "手提包", pinyin: "shǒutíbāo", es: "bolso"),
        Row("tie", fr: "cravate", zh: "领带", pinyin: "lǐngdài", es: "corbata"),
        Row("suitcase", fr: "valise", zh: "行李箱", pinyin: "xínglixiāng", es: "maleta"),
        Row("frisbee", fr: "frisbee", zh: "飞盘", pinyin: "fēipán", es: "frisbee"),
        Row("skis", fr: "skis", zh: "滑雪板", pinyin: "huáxuěbǎn", es: "esquís"),
        Row("snowboard", fr: "snowboard", zh: "单板滑雪板", pinyin: "dānbǎn huáxuěbǎn", es: "snowboard"),
        Row("sports ball", fr: "ballon", zh: "球", pinyin: "qiú", es: "pelota"),
        Row("kite", fr: "cerf-volant", zh: "风筝", pinyin: "fēngzheng", es: "cometa"),
        Row("baseball bat", fr: "batte de baseball", zh: "棒球棒", pinyin: "bàngqiúbàng", es: "bate de béisbol"),
        Row("baseball glove", fr: "gant de baseball", zh: "棒球手套", pinyin: "bàngqiú shǒutào", es: "guante de béisbol"),
        Row("skateboard", fr: "skateboard", zh: "滑板", pinyin: "huábǎn", es: "monopatín"),
        Row("surfboard", fr: "planche de surf", zh: "冲浪板", pinyin: "chōnglàngbǎn", es: "tabla de surf"),
        Row("tennis racket", fr: "raquette de tennis", zh: "网球拍", pinyin: "wǎngqiúpāi", es: "raqueta de tenis"),
        Row("bottle", fr: "bouteille", zh: "瓶子", pinyin: "píngzi", es: "botella"),
        Row("wine glass", fr: "verre à vin", zh: "酒杯", pinyin: "jiǔbēi", es: "copa de vino"),
        Row("cup", fr: "tasse", zh: "杯子", pinyin: "bēizi", es: "taza"),
        Row("fork", fr: "fourchette", zh: "叉子", pinyin: "chāzi", es: "tenedor"),
        Row("knife", fr: "couteau", zh: "刀", pinyin: "dāo", es: "cuchillo"),
        Row("spoon", fr: "cuillère", zh: "勺子", pinyin: "sháozi", es: "cuchara"),
        Row("bowl", fr: "bol", zh: "碗", pinyin: "wǎn", es: "cuenco"),
        Row("banana", fr: "banane", zh: "香蕉", pinyin: "xiāngjiāo", es: "plátano"),
        Row("apple", fr: "pomme", zh: "苹果", pinyin: "píngguǒ", es: "manzana"),
        Row("sandwich", fr: "sandwich", zh: "三明治", pinyin: "sānmíngzhì", es: "sándwich"),
        Row("orange", fr: "orange", zh: "橙子", pinyin: "chéngzi", es: "naranja"),
        Row("broccoli", fr: "brocoli", zh: "西兰花", pinyin: "xīlánhuā", es: "brócoli"),
        Row("carrot", fr: "carotte", zh: "胡萝卜", pinyin: "húluóbo", es: "zanahoria"),
        Row("hot dog", fr: "hot-dog", zh: "热狗", pinyin: "règǒu", es: "perrito caliente"),
        Row("pizza", fr: "pizza", zh: "披萨", pinyin: "pīsà", es: "pizza"),
        Row("donut", fr: "beignet", zh: "甜甜圈", pinyin: "tiántiánquān", es: "dónut"),
        Row("cake", fr: "gâteau", zh: "蛋糕", pinyin: "dàngāo", es: "tarta"),
        Row("chair", fr: "chaise", zh: "椅子", pinyin: "yǐzi", es: "silla"),
        Row("couch", fr: "canapé", zh: "沙发", pinyin: "shāfā", es: "sofá"),
        Row("potted plant", fr: "plante en pot", zh: "盆栽", pinyin: "pénzāi", es: "planta en maceta"),
        Row("bed", fr: "lit", zh: "床", pinyin: "chuáng", es: "cama"),
        Row("dining table", fr: "table", zh: "餐桌", pinyin: "cānzhuō", es: "mesa"),
        Row("toilet", fr: "toilettes", zh: "马桶", pinyin: "mǎtǒng", es: "inodoro"),
        Row("tv", en: "television", fr: "télévision", zh: "电视", pinyin: "diànshì", es: "televisor"),
        Row("laptop", fr: "ordinateur portable", zh: "笔记本电脑", pinyin: "bǐjìběn diànnǎo", es: "portátil"),
        Row("mouse", fr: "souris", zh: "鼠标", pinyin: "shǔbiāo", es: "ratón"),
        Row("remote", en: "remote control", fr: "télécommande", zh: "遥控器", pinyin: "yáokòngqì", es: "mando a distancia"),
        Row("keyboard", fr: "clavier", zh: "键盘", pinyin: "jiànpán", es: "teclado"),
        Row("cell phone", fr: "téléphone portable", zh: "手机", pinyin: "shǒujī", es: "móvil"),
        Row("microwave", fr: "micro-ondes", zh: "微波炉", pinyin: "wēibōlú", es: "microondas"),
        Row("oven", fr: "four", zh: "烤箱", pinyin: "kǎoxiāng", es: "horno"),
        Row("toaster", fr: "grille-pain", zh: "烤面包机", pinyin: "kǎomiànbāojī", es: "tostadora"),
        Row("sink", fr: nil, zh: "水槽", pinyin: "shuǐcáo", es: nil),
        Row("refrigerator", fr: "réfrigérateur", zh: "冰箱", pinyin: "bīngxiāng", es: "frigorífico"),
        Row("book", fr: "livre", zh: "书", pinyin: "shū", es: "libro"),
        Row("clock", fr: "horloge", zh: "钟", pinyin: "zhōng", es: "reloj"),
        Row("vase", fr: "vase", zh: "花瓶", pinyin: "huāpíng", es: "jarrón"),
        Row("scissors", fr: "ciseaux", zh: "剪刀", pinyin: "jiǎndāo", es: "tijeras"),
        Row("teddy bear", fr: "ours en peluche", zh: "泰迪熊", pinyin: "tàidíxióng", es: "oso de peluche"),
        Row("hair drier", en: "hair dryer", fr: "sèche-cheveux", zh: "吹风机", pinyin: "chuīfēngjī", es: "secador de pelo"),
        Row("toothbrush", fr: "brosse à dents", zh: "牙刷", pinyin: "yáshuā", es: "cepillo de dientes"),
    ]
}
