import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DeliveryVsCookApp());
}

// ============================================================
// 공통 유틸
// ============================================================

/// AI가 숫자를 문자열("3,000원")로 줘도 안전하게 int로 변환
int toInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) {
    return int.tryParse(v.replaceAll(RegExp(r'[^0-9-]'), '')) ?? 0;
  }
  return 0;
}

/// 12000 -> "12,000원"
String won(int v) {
  final s = v.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${v < 0 ? '-' : ''}${buf.toString()}원';
}

/// DateTime -> "2026-11-23"
String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ============================================================
// OpenAI API
// ============================================================

// TODO: 여기에 발급받은 OpenAI API 키(sk-proj-...)를 한 줄로 붙여넣으세요
const String kOpenAiApiKey = '';

String get openAiKey => kOpenAiApiKey.replaceAll(RegExp(r'\s'), '');

/// OpenAI에 요청하고 JSON(Map)으로 받아오는 공용 함수
Future<Map<String, dynamic>> callOpenAiJson(
    List<Map<String, dynamic>> content) async {
  final res = await http
      .post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Authorization': 'Bearer $openAiKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'model': 'gpt-4o-mini',
      'temperature': 0.4,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'user', 'content': content},
      ],
    }),
  )
      .timeout(const Duration(seconds: 60));

  if (res.statusCode != 200) {
    throw Exception('OpenAI ${res.statusCode}: ${utf8.decode(res.bodyBytes)}');
  }

  final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final String? text = body['choices']?[0]?['message']?['content'] as String?;
  if (text == null) throw Exception('AI 응답이 비어 있습니다.');

  String cleanJson = text.trim();
  if (cleanJson.startsWith('```')) {
    cleanJson =
        cleanJson.replaceAll(RegExp(r'^```json\s*|^```\s*|```$'), '').trim();
  }
  return jsonDecode(cleanJson) as Map<String, dynamic>;
}

// ============================================================
// 데이터 모델
// ============================================================

/// 재료 / 조미료 한 개
class Ingredient {
  final String name;
  final String amount; // 레시피 사용량. 예: "2개", "1큰술"
  final int price; // 마트 묶음 단위 가격
  final String buyUnit; // 마트 구매 단위. 예: "계란 10구", "대파 1단"

  Ingredient(this.name, this.amount, this.price, [this.buyUnit = '']);
}

List<Ingredient> parseItems(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .map<Ingredient>((e) {
    if (e is Map) {
      return Ingredient(
        e['name']?.toString() ?? '',
        e['amount']?.toString() ?? '',
        toInt(e['price']),
        e['buyUnit']?.toString() ?? '',
      );
    }
    return Ingredient(e.toString(), '', 0);
  })
      .where((i) => i.name.trim().isNotEmpty)
      .toList();
}

/// 조리 단계 하나 (큰 제목 + 세부 내용)
class RecipeStep {
  final String title; // 예: "양념장 만들기"
  final List<String> details; // 세부 절차
  final String tip; // 선택: 팁/주의사항

  RecipeStep(this.title, this.details, this.tip);
}

List<RecipeStep> parseRecipe(dynamic raw) {
  if (raw is! List) return [];
  return raw.map<RecipeStep>((e) {
    if (e is Map) {
      final d = e['details'];
      return RecipeStep(
        (e['title'] ?? '').toString(),
        d is List ? d.map((x) => x.toString()).toList() : <String>[],
        (e['tip'] ?? '').toString(),
      );
    }
    // 예전 형식("1. ...")으로 와도 깨지지 않게 처리
    final s = e.toString().replaceFirst(RegExp(r'^\s*\d+[\.\)]\s*'), '');
    return RecipeStep(s, <String>[], '');
  }).toList();
}

/// AI 분석 결과
class Analysis {
  final String menuName;
  final int menuPrice; // 음식값
  final int deliveryFee; // 배달비
  final int deliveryWaitMin;
  final int cookUnitPrice; // 해먹기 1인분 비용
  final int initialGroceryCost; // 처음 장보기 총액
  final int cookTimeMin;
  final int breakEvenMeals;
  final String verdict;
  final List<Ingredient> ingredients; // 주재료·부재료
  final List<Ingredient> seasonings; // 조미료 (하나하나 분리)
  final List<RecipeStep> recipe;

  Analysis({
    required this.menuName,
    required this.menuPrice,
    required this.deliveryFee,
    required this.deliveryWaitMin,
    required this.cookUnitPrice,
    required this.initialGroceryCost,
    required this.cookTimeMin,
    required this.breakEvenMeals,
    required this.verdict,
    required this.ingredients,
    required this.seasonings,
    required this.recipe,
  });

  /// 배달 총액 = 음식값 + 배달비 (AI 계산을 믿지 않고 앱에서 직접 더함)
  int get deliveryTotal => menuPrice + deliveryFee;

  /// 한 끼 해먹으면 아끼는 금액
  int get savedPerMeal {
    final diff = deliveryTotal - cookUnitPrice;
    return diff > 0 ? diff : 0;
  }

  factory Analysis.fromJson(Map<String, dynamic> j, {int? feeOverride}) {
    final ings = parseItems(j['ingredients'] ?? j['groceryChecklist']);
    final seas = parseItems(j['seasonings']);
    // 초기 장보기 비용 = 모든 재료의 묶음 가격 합 (AI 값보다 앱 계산 우선)
    final bundleSum =
    [...ings, ...seas].fold<int>(0, (s, it) => s + it.price);
    return Analysis(
      menuName: j['menuName']?.toString() ?? '메뉴',
      menuPrice: toInt(j['menuPrice'] ?? j['deliveryPrice']),
      deliveryFee: feeOverride ?? toInt(j['deliveryFee']),
      deliveryWaitMin: toInt(j['deliveryWaitMin']),
      cookUnitPrice: toInt(j['cookUnitPrice']),
      initialGroceryCost:
      bundleSum > 0 ? bundleSum : toInt(j['initialGroceryCost']),
      cookTimeMin: toInt(j['cookTimeMin']),
      breakEvenMeals: toInt(j['breakEvenMeals']),
      verdict: j['aiVerdict']?.toString() ?? '',
      ingredients: ings,
      seasonings: seas,
      recipe: parseRecipe(j['quickRecipe']),
    );
  }
}

/// 캘린더에 남는 하루 기록
class MealRecord {
  final String date; // yyyy-MM-dd
  final String type; // 'delivery' | 'cook'
  final String menu;
  final int amount; // 실제 쓴 돈
  final int saved; // 해먹기로 아낀 돈

  MealRecord({
    required this.date,
    required this.type,
    required this.menu,
    required this.amount,
    this.saved = 0,
  });

  Map<String, dynamic> toJson() => {
    'date': date,
    'type': type,
    'menu': menu,
    'amount': amount,
    'saved': saved,
  };

  factory MealRecord.fromJson(Map<String, dynamic> j) => MealRecord(
    date: j['date'].toString(),
    type: j['type'].toString(),
    menu: (j['menu'] ?? '').toString(),
    amount: toInt(j['amount']),
    saved: toInt(j['saved']),
  );
}

/// SharedPreferences에 기록 목록 저장
class RecordStore {
  static const _key = 'meal_records';

  static Future<List<MealRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    return list
        .map((s) => MealRecord.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> add(MealRecord r) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.add(jsonEncode(r.toJson()));
    await prefs.setStringList(_key, list);
  }
}

// ============================================================
// 앱
// ============================================================

class DeliveryVsCookApp extends StatelessWidget {
  const DeliveryVsCookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '배달 vs 해먹기 손익 계산기',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF6B35)),
        useMaterial3: true,
      ),
      home: const MainHomePage(),
    );
  }
}

// ============================================================
// 1. 메인 화면 (분석)
// ============================================================

class MainHomePage extends StatefulWidget {
  const MainHomePage({super.key});

  @override
  State<MainHomePage> createState() => _MainHomePageState();
}

class _MainHomePageState extends State<MainHomePage> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _menuController = TextEditingController();
  final TextEditingController _feeController = TextEditingController();

  File? _selectedImage;
  bool _isLoading = false;
  Analysis? _analysis;

  // 이번 달 요약
  int _monthDeliverySpent = 0;
  int _monthSaved = 0;

  @override
  void initState() {
    super.initState();
    _loadMonthlyStats();
  }

  @override
  void dispose() {
    _menuController.dispose();
    _feeController.dispose();
    super.dispose();
  }

  Future<void> _loadMonthlyStats() async {
    final records = await RecordStore.load();
    final now = DateTime.now();
    final prefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    int delivery = 0, saved = 0;
    for (final r in records.where((r) => r.date.startsWith(prefix))) {
      if (r.type == 'delivery') delivery += r.amount;
      if (r.type == 'cook') saved += r.saved;
    }
    if (!mounted) return;
    setState(() {
      _monthDeliverySpent = delivery;
      _monthSaved = saved;
    });
  }

  Future<void> _openStats({String? banner}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StatsPage(banner: banner)),
    );
    _loadMonthlyStats();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
    }
  }

  void _snack(String msg, {int seconds = 3}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: Duration(seconds: seconds)),
    );
  }

  Future<void> _analyzeCost() async {
    if (openAiKey.isEmpty) {
      _snack('코드 맨 위 kOpenAiApiKey 변수에 OpenAI API 키를 먼저 입력해 주세요!');
      return;
    }
    if (_selectedImage == null && _menuController.text.trim().isEmpty) {
      _snack('배달 캡처 이미지를 선택하거나 메뉴명을 입력해 주세요.');
      return;
    }

    // 사용자가 배달비를 직접 입력했으면 그 값을 우선 사용
    final feeText = _feeController.text.trim();
    final int? feeOverride = feeText.isEmpty ? null : toInt(feeText);

    setState(() {
      _isLoading = true;
      _analysis = null;
    });

    try {
      final prompt = '''
당신은 1인 가구 대학생의 합리적 식비 선택을 돕는 AI 재무·요리 분석가입니다.
입력된 배달 주문 캡처 이미지 또는 텍스트 메뉴를 분석하여 [배달 선택 시]와 [직접 조리 선택 시]의 기회비용을 비교하세요.

규칙:
1. menuPrice는 음식값만, deliveryFee는 배달비(배달팁)만 따로 적으세요.
   캡처에 배달팁이 보이면 그 금액을, 없으면 한국 배달앱 평균 수준(약 3000원)으로 추정하세요.
2. 배달 총액(음식값+배달비)과 해먹기 비용을 비교해서 aiVerdict를 작성하세요.
3. ingredients에는 주재료·부재료(고기, 채소, 떡, 면 등)만 넣으세요.
4. seasonings에는 조미료를 절대 "양념"으로 묶지 말고 하나하나 분리해서 넣으세요.
   예: 간장, 소금, 설탕, 고추장, 고춧가루, 다진 마늘, 참기름, 후추, 다시다, 굴소스 등.
5. 가격은 반드시 "한국 마트에서 실제로 살 수 있는 최소 묶음 단위" 기준으로 적으세요.
   - amount: 이 요리 1인분에 실제로 쓰는 양 (예: "2개", "1/2대", "1큰술")
   - buyUnit: 마트에서 파는 묶음 단위 (예: 계란 → "계란 10구", 대파 → "대파 1단",
     양파 → "양파 1.5kg 망", 돼지고기 → "앞다리살 500g 팩", 간장 → "진간장 500ml",
     다시다 → "다시다 100g", 소금 → "꽃소금 500g")
   - price: buyUnit 묶음 전체의 가격. 계란 1알처럼 낱개로 살 수 없는 단위로 계산하지 마세요.
6. initialGroceryCost는 모든 재료·조미료 price(묶음 가격)의 합입니다.
   cookUnitPrice는 묶음 중 이번 1인분에 실제로 쓰는 양만큼만 나눠 계산한 1인분 원가입니다.
   (예: 계란 10구 3500원 중 2개 사용 → 700원)
   breakEvenMeals는 묶음으로 산 재료를 다 쓰려면 몇 끼를 해 먹어야 하는지, 그리고 그때 배달 대비 얼마나 이득인지 기준으로 판단하세요.
7. quickRecipe는 요리 초보도 따라 할 수 있게 자세히 쓰되, 단계별로 나누세요.
   - title: 단계의 큰 제목 (예: "재료 손질", "양념장 만들기", "볶기", "마무리")
   - details: 그 단계의 세부 절차를 한 문장씩 배열로. 불 세기(약불/중불/강불), 시간(분), 크기(cm), 조미료 이름과 양을 구체적으로.
   - tip: 실패하지 않는 팁이나 주의사항 한 문장 (없으면 빈 문자열)
   - 보통 4~6단계로 구성하세요.

반드시 아래 JSON 형식으로만 응답하세요:
{
  "menuName": "추출된 대표 메뉴명",
  "menuPrice": 18000,
  "deliveryFee": 3000,
  "deliveryWaitMin": 40,
  "cookUnitPrice": 3200,
  "initialGroceryCost": 12000,
  "cookTimeMin": 15,
  "breakEvenMeals": 2,
  "aiVerdict": "2끼 이상 해 먹으면 초기 장보기 비용이 상쇄되며, 남은 재료로 볶음밥 활용이 가능합니다.",
  "ingredients": [
    {"name": "떡볶이 떡", "amount": "200g", "buyUnit": "떡볶이 떡 500g", "price": 2500},
    {"name": "어묵", "amount": "2장", "buyUnit": "사각어묵 6장 팩", "price": 2000},
    {"name": "계란", "amount": "2개", "buyUnit": "계란 10구", "price": 3500},
    {"name": "대파", "amount": "1/2대", "buyUnit": "대파 1단", "price": 2500}
  ],
  "seasonings": [
    {"name": "고추장", "amount": "2큰술", "buyUnit": "고추장 500g", "price": 5000},
    {"name": "고춧가루", "amount": "1큰술", "buyUnit": "고춧가루 200g", "price": 6000},
    {"name": "설탕", "amount": "1큰술", "buyUnit": "백설탕 1kg", "price": 2500},
    {"name": "간장", "amount": "1큰술", "buyUnit": "진간장 500ml", "price": 3500},
    {"name": "다시다", "amount": "1작은술", "buyUnit": "다시다 100g", "price": 3000}
  ],
  "quickRecipe": [
    {
      "title": "재료 손질",
      "details": [
        "떡볶이 떡 200g을 찬물에 5분간 담가 불린다.",
        "어묵 2장을 한 입 크기(약 3cm)로 썬다.",
        "대파 1/2대를 어슷하게 썬다."
      ],
      "tip": "굳은 떡은 끓는 물에 30초 데치면 부드러워져요."
    },
    {
      "title": "양념장 만들기",
      "details": [
        "그릇에 고추장 2큰술, 고춧가루 1큰술, 설탕 1큰술, 간장 1큰술, 다시다 1작은술을 넣는다.",
        "숟가락으로 덩어리 없이 잘 섞는다."
      ],
      "tip": ""
    },
    {
      "title": "끓이기",
      "details": [
        "냄비에 물 300ml를 붓고 강불로 끓인다.",
        "물이 끓으면 양념장을 넣고 풀어준다.",
        "떡과 어묵을 넣고 중불에서 7분간 저어가며 졸인다."
      ],
      "tip": "바닥에 눌어붙지 않게 자주 저어주세요."
    },
    {
      "title": "마무리",
      "details": [
        "대파를 넣고 1분 더 끓인다.",
        "국물이 걸쭉해지면 불을 끄고 그릇에 담는다."
      ],
      "tip": ""
    }
  ]
}

사용자 추가 입력 텍스트: "${_menuController.text}"
사용자가 입력한 배달비: "${feeText.isEmpty ? '없음' : feeText}"
''';

      final List<Map<String, dynamic>> content = [
        {'type': 'text', 'text': prompt},
      ];
      if (_selectedImage != null) {
        final b64 = base64Encode(await _selectedImage!.readAsBytes());
        content.add({
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$b64'},
        });
      }

      final decoded = await callOpenAiJson(content);
      setState(() {
        _analysis = Analysis.fromJson(decoded, feeOverride: feeOverride);
      });
    } catch (e) {
      debugPrint('OpenAI API Error: $e');
      _snack('API 오류: $e', seconds: 6);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// [배달 주문 확정] → 기록 저장 후 통계/캘린더 화면으로 이동
  Future<void> _confirmDelivery(Analysis a) async {
    // 한 번 더 되묻는 팝업
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('진짜 배달 시킬 건가요?? 🥺'),
        content: Text(
          '${a.menuName} 배달 비용은 배달비 포함 ${won(a.deliveryTotal)}이에요.\n\n'
              '해 먹으면 ${won(a.cookUnitPrice)}으로 '
              '${won(a.savedPerMeal)}을 아낄 수 있어요!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('아니요, 해 먹을래요'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('네, 시킬래요'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return; // 취소하거나 바깥을 누르면 기록 안 함

    await RecordStore.add(MealRecord(
      date: dateKey(DateTime.now()),
      type: 'delivery',
      menu: a.menuName,
      amount: a.deliveryTotal,
    ));
    if (!mounted) return;
    await _openStats(
        banner: '🛵 ${a.menuName} 배달 ${won(a.deliveryTotal)}이 기록되었어요.');
  }

  /// [해먹기 도전!] → 체크리스트 화면으로 이동
  Future<void> _startCookChallenge(Analysis a) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CookChecklistPage(analysis: a)),
    );
    _loadMonthlyStats();
  }

  @override
  Widget build(BuildContext context) {
    final a = _analysis;
    return Scaffold(
      appBar: AppBar(
        title: const Text('배달 vs 해먹기 AI 손익 비교'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '기록 캘린더',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => _openStats(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 이번 달 요약 카드 (누르면 통계 화면)
            Card(
              color: Colors.orange.shade50,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openStats(),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _summaryColumn('이번 달 배달 지출',
                              won(_monthDeliverySpent), Colors.redAccent),
                          Container(
                              width: 1, height: 36, color: Colors.black12),
                          _summaryColumn(
                              '해 먹기로 아낀 금액', won(_monthSaved), Colors.teal),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('캘린더·상세 기록 보기 >',
                          style:
                          TextStyle(fontSize: 12, color: Colors.black45)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            OutlinedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.photo_library),
              label: Text(_selectedImage == null
                  ? '배달 앱 장바구니/주문 내역 캡처 업로드'
                  : '캡처 이미지 선택 완료 (변경하려면 클릭)'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            if (_selectedImage != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(_selectedImage!,
                    height: 160, fit: BoxFit.cover),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _menuController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '메뉴명 직접 입력 (예: 엽기떡볶이 18000원)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _feeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '배달비 (선택, 예: 3500)',
                helperText: '비워두면 캡처에서 읽거나 AI가 평균 배달비로 추정해요',
                suffixText: '원',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isLoading ? null : _analyzeCost,
              icon: const Icon(Icons.analytics),
              label: const Text('AI 기회비용 실시간 비교하기'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 20),

            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),

            if (a != null) ...[
              Text(
                '📊 [${a.menuName}] 실시간 비교 리포트',
                style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          children: [
                            const Text('🛵 배달 주문 시',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text(won(a.deliveryTotal),
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red)),
                            const SizedBox(height: 4),
                            Text('음식 ${won(a.menuPrice)}',
                                style: const TextStyle(fontSize: 12)),
                            Text('+ 배달비 ${won(a.deliveryFee)}',
                                style: const TextStyle(fontSize: 12)),
                            Text('${a.deliveryWaitMin}분 대기',
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Card(
                      color: Colors.teal.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          children: [
                            const Text('🍳 직접 조리 시',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('1인분 ${won(a.cookUnitPrice)}',
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.teal)),
                            const SizedBox(height: 4),
                            Text('${a.cookTimeMin}분 조리',
                                style: const TextStyle(fontSize: 12)),
                            Text('묶음 장보기 ${won(a.initialGroceryCost)}',
                                style: const TextStyle(fontSize: 12)),
                            Text('${a.breakEvenMeals}끼부터 이득',
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Card(
                color: Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '💰 해 먹으면 한 끼에 ${won(a.savedPerMeal)} 절약 (배달비 포함 기준)',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('💡 AI 객관적 판정 및 남은 재료 활용',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(a.verdict),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _confirmDelivery(a),
                      child: const Text('배달 주문 확정'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _startCookChallenge(a),
                      child: const Text('해 먹기 도전!'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryColumn(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

// ============================================================
// 2. 해먹기 1단계: 재료 체크리스트
// ============================================================

class CookChecklistPage extends StatefulWidget {
  final Analysis analysis;
  const CookChecklistPage({super.key, required this.analysis});

  @override
  State<CookChecklistPage> createState() => _CookChecklistPageState();
}

class _CookChecklistPageState extends State<CookChecklistPage> {
  // 직접 추가할 수 있도록 AI 목록을 복사해서 사용
  late List<Ingredient> _ings;
  late List<Ingredient> _seas;
  late List<bool> _ingChecked;
  late List<bool> _seaChecked;
  final Set<Ingredient> _custom = {}; // 사용자가 직접 추가한 항목

  @override
  void initState() {
    super.initState();
    _ings = [...widget.analysis.ingredients];
    _seas = [...widget.analysis.seasonings];
    _ingChecked = List<bool>.filled(_ings.length, false, growable: true);
    _seaChecked = List<bool>.filled(_seas.length, false, growable: true);
  }

  void _setAll(bool v) {
    setState(() {
      _ingChecked = List<bool>.filled(_ings.length, v, growable: true);
      _seaChecked = List<bool>.filled(_seas.length, v, growable: true);
    });
  }

  /// [+ 재료 직접 추가] 팝업
  Future<void> _addCustomItem() async {
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final unitCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    bool isSeasoning = false;

    final Ingredient? item = await showDialog<Ingredient>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('재료 직접 추가'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('🥩 재료')),
                    ButtonSegment(value: true, label: Text('🧂 조미료')),
                  ],
                  selected: {isSeasoning},
                  onSelectionChanged: (s) =>
                      setDlg(() => isSeasoning = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '재료 이름 (필수)',
                    hintText: '예: 치즈, 참기름',
                  ),
                ),
                TextField(
                  controller: amountCtrl,
                  decoration: const InputDecoration(
                    labelText: '필요량 (선택)',
                    hintText: '예: 1장, 1작은술',
                  ),
                ),
                TextField(
                  controller: unitCtrl,
                  decoration: const InputDecoration(
                    labelText: '마트 구매 단위 (선택)',
                    hintText: '예: 슬라이스 치즈 10매',
                  ),
                ),
                TextField(
                  controller: priceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '가격 (선택)',
                    suffixText: '원',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return; // 이름 없으면 추가 안 함
                Navigator.pop(
                  ctx,
                  Ingredient(
                    name,
                    amountCtrl.text.trim(),
                    toInt(priceCtrl.text),
                    unitCtrl.text.trim(),
                  ),
                );
              },
              child: const Text('추가'),
            ),
          ],
        ),
      ),
    );

    if (item == null || !mounted) return;
    setState(() {
      _custom.add(item);
      // 직접 추가한 재료는 사야 하는 재료로 보고 자동 체크
      if (isSeasoning) {
        _seas.add(item);
        _seaChecked.add(true);
      } else {
        _ings.add(item);
        _ingChecked.add(true);
      }
    });
  }

  void _removeCustom(List<Ingredient> items, List<bool> checked, int i) {
    setState(() {
      _custom.remove(items[i]);
      items.removeAt(i);
      checked.removeAt(i);
    });
  }

  void _done() {
    final toBuyIng = <Ingredient>[];
    final toBuySea = <Ingredient>[];
    for (int i = 0; i < _ings.length; i++) {
      if (_ingChecked[i]) toBuyIng.add(_ings[i]);
    }
    for (int i = 0; i < _seas.length; i++) {
      if (_seaChecked[i]) toBuySea.add(_seas[i]);
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShoppingListPage(
          analysis: widget.analysis,
          ingredients: toBuyIng,
          seasonings: toBuySea,
          customIngredients: _ings.where(_custom.contains).toList(),
          customSeasonings: _seas.where(_custom.contains).toList(),
        ),
      ),
    );
  }

  Widget _section(String title, List<Ingredient> items, List<bool> checked) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(title,
              style:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('항목 없음', style: TextStyle(color: Colors.black45)),
          ),
        ...List.generate(items.length, (i) {
          final it = items[i];
          final isCustom = _custom.contains(it);
          final lines = [
            if (it.amount.isNotEmpty) '필요량: ${it.amount}',
            if (it.buyUnit.isNotEmpty)
              '구매: ${it.buyUnit}${it.price > 0 ? ' (약 ${won(it.price)})' : ''}'
            else if (it.price > 0)
              '가격: 약 ${won(it.price)}',
          ];
          return CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Row(
              children: [
                Flexible(child: Text(it.name)),
                if (isCustom)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('직접 추가',
                        style: TextStyle(fontSize: 11, color: Colors.blue)),
                  ),
              ],
            ),
            subtitle: lines.isEmpty ? null : Text(lines.join('\n')),
            secondary: isCustom
                ? IconButton(
              tooltip: '삭제',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => _removeCustom(items, checked, i),
            )
                : null,
            value: checked[i],
            onChanged: (v) => setState(() => checked[i] = v ?? false),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    return Scaffold(
      appBar: AppBar(title: Text('🍳 ${a.menuName} 해 먹기 도전')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.orange.shade50,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '🛒 집에 없어서 사야 하는 재료를 체크해 주세요.\n'
                    '체크한 재료만 다음 화면의 구매 목록에 나와요.\n'
                    '목록에 없는 재료는 맨 아래 [+ 재료 직접 추가]로 넣을 수 있어요.',
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () => _setAll(true), child: const Text('전체 선택')),
              TextButton(
                  onPressed: () => _setAll(false),
                  child: const Text('전체 해제')),
            ],
          ),
          _section('🥩 주재료·부재료', _ings, _ingChecked),
          const Divider(),
          _section('🧂 조미료', _seas, _seaChecked),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _addCustomItem,
            icon: const Icon(Icons.add),
            label: const Text('재료 직접 추가'),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12)),
          ),
          const SizedBox(height: 80),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _done,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('체크 완료 → 구매 목록 보기'),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 3. 해먹기 2단계: 내가 사야 할 재료만
// ============================================================

class ShoppingListPage extends StatelessWidget {
  final Analysis analysis;
  final List<Ingredient> ingredients;
  final List<Ingredient> seasonings;
  final List<Ingredient> customIngredients; // 직접 추가한 재료 (레시피 반영용)
  final List<Ingredient> customSeasonings;

  const ShoppingListPage({
    super.key,
    required this.analysis,
    required this.ingredients,
    required this.seasonings,
    this.customIngredients = const [],
    this.customSeasonings = const [],
  });

  @override
  Widget build(BuildContext context) {
    final all = [...ingredients, ...seasonings];
    final total = all.fold<int>(0, (sum, it) => sum + it.price);

    Widget tile(Ingredient it) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.shopping_basket_outlined),
      title: Text(it.buyUnit.isNotEmpty ? it.buyUnit : it.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle:
      it.amount.isEmpty ? null : Text('이번 요리에 쓰는 양: ${it.amount}'),
      trailing: Text(it.price > 0 ? '약 ${won(it.price)}' : '',
          style: const TextStyle(fontWeight: FontWeight.bold)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('🛒 구매해야 할 재료')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (all.isEmpty)
            Card(
              color: Colors.teal.shade50,
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('🎉 살 재료가 없어요! 집에 있는 재료로 바로 요리할 수 있어요.'),
              ),
            )
          else ...[
            Card(
              color: Colors.teal.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('예상 장보기 비용'),
                    const SizedBox(height: 4),
                    Text(won(total),
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal)),
                    const SizedBox(height: 4),
                    Text('총 ${all.length}개 품목',
                        style: const TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
            ),
            if (ingredients.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('🥩 주재료·부재료',
                    style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              ...ingredients.map(tile),
            ],
            if (seasonings.isNotEmpty) ...[
              const Divider(),
              const Text('🧂 조미료',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ...seasonings.map(tile),
            ],
            const SizedBox(height: 8),
            const Text(
                '※ 마트에서 파는 묶음 단위(계란 10구, 대파 1단 등) 기준 가격이에요.\n'
                    '※ 가격은 AI가 추정한 대략적인 금액이에요.',
                style: TextStyle(fontSize: 12, color: Colors.black45)),
          ],
          const SizedBox(height: 80),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => RecipePage(
                    analysis: analysis,
                    customIngredients: customIngredients,
                    customSeasonings: customSeasonings,
                  )),
            ),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('장보기 완료 → 레시피 보기'),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 4. 해먹기 3단계: 레시피 + 조리 완료 기록
// ============================================================

class RecipePage extends StatefulWidget {
  final Analysis analysis;
  final List<Ingredient> customIngredients; // 체크리스트에서 직접 추가한 재료
  final List<Ingredient> customSeasonings; // 체크리스트에서 직접 추가한 조미료

  const RecipePage({
    super.key,
    required this.analysis,
    this.customIngredients = const [],
    this.customSeasonings = const [],
  });

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  late List<RecipeStep> _recipe;
  late List<Ingredient> _ingredients;
  late List<Ingredient> _seasonings;
  late int _cookTimeMin;
  bool _loading = false;
  String? _error;

  bool get _hasCustom =>
      widget.customIngredients.isNotEmpty || widget.customSeasonings.isNotEmpty;

  List<String> get _customNames => [
    ...widget.customIngredients.map((e) => e.name),
    ...widget.customSeasonings.map((e) => e.name),
  ];

  // 직접 추가한 재료 이름 (양이 채워져 객체가 바뀌어도 구분되도록 이름으로 관리)
  Set<String> get _customNameSet => _customNames.toSet();

  @override
  void initState() {
    super.initState();
    final a = widget.analysis;
    _recipe = a.recipe;
    _ingredients = [...a.ingredients, ...widget.customIngredients];
    _seasonings = [...a.seasonings, ...widget.customSeasonings];
    _cookTimeMin = a.cookTimeMin;
    if (_hasCustom) _regenerateRecipe();
  }

  String _itemLine(Ingredient it, bool custom) =>
      '- ${it.name}${it.amount.isNotEmpty ? ' (${it.amount})' : ' (양 미정)'}'
          '${custom ? ' ← 사용자가 직접 추가' : ''}';

  /// 직접 추가한 재료를 넣어서 AI에게 레시피를 다시 받아오기
  Future<void> _regenerateRecipe() async {
    if (openAiKey.isEmpty) {
      setState(() => _error = 'API 키가 없어서 기존 레시피를 보여드려요.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final a = widget.analysis;
    final customSet = _customNameSet;
    final ingText = _ingredients
        .map((e) => _itemLine(e, customSet.contains(e.name)))
        .join('\n');
    final seaText = _seasonings
        .map((e) => _itemLine(e, customSet.contains(e.name)))
        .join('\n');

    final prompt = '''
당신은 요리 초보 대학생에게 레시피를 알려주는 요리 선생님입니다.
메뉴 "${a.menuName}" 1인분 레시피를 아래 재료·조미료를 "모두" 사용해서 다시 작성하세요.
특히 "사용자가 직접 추가"한 재료는 반드시 레시피 단계 안에 자연스럽게 넣어야 합니다
(언제, 어떻게, 얼마나 넣는지 구체적으로).

[주재료·부재료]
$ingText

[조미료]
$seaText

규칙:
- quickRecipe는 4~6단계. 각 단계는 title(큰 제목), details(세부 절차 문장 배열), tip(팁, 없으면 빈 문자열).
- details에는 불 세기, 시간(분), 크기(cm), 재료·조미료 이름과 양을 구체적으로.
- "양 미정"인 재료는 1인분에 알맞은 양을 정해서 amounts에 적으세요.
- 기존 원래 레시피 맛은 유지하되, 추가 재료가 어울리게 조리 순서를 조정하세요.

반드시 아래 JSON 형식으로만 응답하세요:
{
  "cookTimeMin": 15,
  "amounts": [{"name": "치즈", "amount": "1장"}],
  "quickRecipe": [
    {"title": "재료 손질", "details": ["...", "..."], "tip": ""}
  ]
}
''';

    try {
      final res = await callOpenAiJson([
        {'type': 'text', 'text': prompt},
      ]);
      final newRecipe = parseRecipe(res['quickRecipe']);
      if (newRecipe.isEmpty) throw Exception('레시피가 비어 있어요.');

      // AI가 정해준 양으로 "양 미정" 재료 채우기
      final Map<String, String> amounts = {};
      final rawAmounts = res['amounts'];
      if (rawAmounts is List) {
        for (final m in rawAmounts) {
          if (m is Map && m['name'] != null) {
            amounts[m['name'].toString()] = (m['amount'] ?? '').toString();
          }
        }
      }
      Ingredient fill(Ingredient it) =>
          it.amount.isEmpty && (amounts[it.name] ?? '').isNotEmpty
              ? Ingredient(it.name, amounts[it.name]!, it.price, it.buyUnit)
              : it;

      if (!mounted) return;
      setState(() {
        _recipe = newRecipe;
        _ingredients = _ingredients.map(fill).toList();
        _seasonings = _seasonings.map(fill).toList();
        final t = toInt(res['cookTimeMin']);
        if (t > 0) _cookTimeMin = t;
      });
    } catch (e) {
      debugPrint('Recipe regenerate error: $e');
      if (!mounted) return;
      setState(() => _error = '레시피 다시 만들기에 실패해서 기존 레시피를 보여드려요.\n($e)');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _complete() async {
    final a = widget.analysis;
    await RecordStore.add(MealRecord(
      date: dateKey(DateTime.now()),
      type: 'cook',
      menu: a.menuName,
      amount: a.cookUnitPrice,
      saved: a.savedPerMeal,
    ));
    if (!mounted) return;
    // 체크리스트·구매목록·레시피 화면을 닫고 통계 화면으로 이동
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => StatsPage(
          banner: '🍳 ${a.menuName} 해 먹기 성공! ${won(a.savedPerMeal)} 아꼈어요.',
        ),
      ),
          (route) => route.isFirst,
    );
  }

  /// 재료/조미료 계량표의 한 줄
  Widget _amountRow(Ingredient it, bool custom) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(custom ? '${it.name} ✨' : it.name,
                style: TextStyle(
                    color: custom ? Colors.blue.shade700 : null,
                    fontWeight: custom ? FontWeight.w600 : null)),
          ),
          Text(it.amount.isEmpty ? '-' : it.amount,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// 단계 카드: [번호 + 큰 제목] / 세부 절차 목록 / 팁
  Widget _stepCard(int no, RecipeStep step) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: primary,
                  child: Text('$no',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(step.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            if (step.details.isNotEmpty) const SizedBox(height: 10),
            for (int j = 0; j < step.details.length; j++)
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text('$no-${j + 1}',
                          style: TextStyle(
                              color: primary, fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                      child: Text(step.details[j],
                          style: const TextStyle(height: 1.4)),
                    ),
                  ],
                ),
              ),
            if (step.tip.trim().isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child:
                Text('💡 ${step.tip}', style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final customSet = _customNameSet;

    return Scaffold(
      appBar: AppBar(title: Text('⏱️ ${a.menuName} 레시피')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 직접 추가한 재료 반영 안내
          if (_hasCustom && !_loading && _error == null)
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                    '✨ 직접 추가한 재료(${_customNames.join(', ')})를 넣어서 레시피를 다시 만들었어요.'),
              ),
            ),
          if (_error != null)
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!),
                    if (openAiKey.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _regenerateRecipe,
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 시도'),
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // 재료 & 조미료 계량표
          const Text('📋 재료·조미료 계량표 (1인분)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('🥩 재료',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.black54)),
                  if (_ingredients.isEmpty) const Text('정보 없음'),
                  ..._ingredients
                      .map((it) => _amountRow(it, customSet.contains(it.name))),
                  const Divider(),
                  const Text('🧂 조미료',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.black54)),
                  if (_seasonings.isEmpty) const Text('정보 없음'),
                  ..._seasonings
                      .map((it) => _amountRow(it, customSet.contains(it.name))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Text('👩‍🍳 조리 순서 (약 $_cookTimeMin분)',
              style:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),

          if (_loading)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      '추가한 재료(${_customNames.join(', ')})를 반영해서\n레시피를 다시 만드는 중이에요...',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else ...[
            if (_recipe.isNotEmpty)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (int i = 0; i < _recipe.length; i++) ...[
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${i + 1}. ${_recipe[i].title}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                    if (i < _recipe.length - 1)
                      const Icon(Icons.arrow_forward,
                          size: 14, color: Colors.black38),
                  ],
                ],
              ),
            const SizedBox(height: 10),
            for (int i = 0; i < _recipe.length; i++)
              _stepCard(i + 1, _recipe[i]),
          ],
          const SizedBox(height: 80),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _loading ? null : _complete,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: Text('조리 완료! (${won(a.savedPerMeal)} 아끼기 기록)'),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 5. 누적 금액 + 월별 캘린더 화면
// ============================================================

class StatsPage extends StatefulWidget {
  final String? banner; // 방금 기록한 내용 안내
  const StatsPage({super.key, this.banner});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<MealRecord> _records = [];
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _selectedDay = dateKey(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await RecordStore.load();
    if (!mounted) return;
    setState(() => _records = r);
  }

  String get _monthPrefix =>
      '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  List<MealRecord> get _monthRecords =>
      _records.where((r) => r.date.startsWith(_monthPrefix)).toList();

  void _moveMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selectedDay = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final monthRecs = _monthRecords;
    final deliveries = monthRecs.where((r) => r.type == 'delivery').toList();
    final cooks = monthRecs.where((r) => r.type == 'cook').toList();
    final deliverySum = deliveries.fold<int>(0, (s, r) => s + r.amount);
    final cookSum = cooks.fold<int>(0, (s, r) => s + r.amount);
    final savedSum = cooks.fold<int>(0, (s, r) => s + r.saved);

    final dayRecs = _selectedDay == null
        ? <MealRecord>[]
        : _records.where((r) => r.date == _selectedDay).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('📅 식비 기록')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.banner != null)
            Card(
              color: Colors.amber.shade100,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(widget.banner!,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),

          // 월 이동
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  onPressed: () => _moveMonth(-1),
                  icon: const Icon(Icons.chevron_left)),
              Text('${_month.year}년 ${_month.month}월',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                  onPressed: () => _moveMonth(1),
                  icon: const Icon(Icons.chevron_right)),
            ],
          ),

          // 누적 금액 카드
          Row(
            children: [
              Expanded(
                child: _statCard('🛵 배달 지출', won(deliverySum),
                    '${deliveries.length}회', Colors.red.shade50, Colors.red),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _statCard('🍳 해먹기 지출', won(cookSum),
                    '${cooks.length}회', Colors.teal.shade50, Colors.teal),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _statCard('💰 해 먹어서 아낀 금액', won(savedSum), '배달비 포함 기준',
              Colors.amber.shade50, Colors.orange.shade800),
          const SizedBox(height: 16),

          // 캘린더
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _buildCalendar(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            children: [
              _legend(Colors.red.shade300, '배달'),
              _legend(Colors.teal.shade300, '해먹기'),
              _legend(Colors.purple.shade200, '둘 다'),
            ],
          ),
          const SizedBox(height: 16),

          // 선택한 날짜 상세
          if (_selectedDay != null) ...[
            Text('$_selectedDay 기록',
                style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (dayRecs.isEmpty)
              const Text('기록 없음', style: TextStyle(color: Colors.black45)),
            ...dayRecs.map((r) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Text(r.type == 'delivery' ? '🛵' : '🍳',
                  style: const TextStyle(fontSize: 22)),
              title: Text(r.menu),
              subtitle: Text(r.type == 'delivery'
                  ? '배달 (배달비 포함)'
                  : '해먹기 · ${won(r.saved)} 절약'),
              trailing: Text(won(r.amount),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            )),
          ],
        ],
      ),
    );
  }

  Widget _buildCalendar() {
    final first = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final offset = first.weekday % 7; // 일요일 시작
    final todayKey = dateKey(DateTime.now());

    // 날짜별 기록 종류 모으기
    final Map<String, Set<String>> typesByDay = {};
    for (final r in _monthRecords) {
      typesByDay.putIfAbsent(r.date, () => <String>{}).add(r.type);
    }

    final cells = <Widget>[];
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    for (int i = 0; i < 7; i++) {
      cells.add(Center(
        child: Text(weekdays[i],
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: i == 0
                    ? Colors.red
                    : (i == 6 ? Colors.blue : Colors.black54))),
      ));
    }
    for (int i = 0; i < offset; i++) {
      cells.add(const SizedBox());
    }
    for (int d = 1; d <= daysInMonth; d++) {
      final key = dateKey(DateTime(_month.year, _month.month, d));
      final types = typesByDay[key] ?? <String>{};
      Color? bg;
      if (types.contains('delivery') && types.contains('cook')) {
        bg = Colors.purple.shade200;
      } else if (types.contains('delivery')) {
        bg = Colors.red.shade300;
      } else if (types.contains('cook')) {
        bg = Colors.teal.shade300;
      }
      final selected = key == _selectedDay;

      cells.add(GestureDetector(
        onTap: () => setState(() => _selectedDay = key),
        child: Container(
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: Colors.black87, width: 2)
                : (key == todayKey
                ? Border.all(color: Colors.orange, width: 2)
                : null),
          ),
          alignment: Alignment.center,
          child: Text('$d',
              style: TextStyle(
                  color: bg != null ? Colors.white : Colors.black87,
                  fontWeight:
                  bg != null ? FontWeight.bold : FontWeight.normal)),
        ),
      ));
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cells,
    );
  }

  Widget _statCard(
      String title, String value, String sub, Color bg, Color fg) {
    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Text(title, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: fg)),
            Text(sub,
                style: const TextStyle(fontSize: 12, color: Colors.black45)),
          ],
        ),
      ),
    );
  }

  Widget _legend(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
