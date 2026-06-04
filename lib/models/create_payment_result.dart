import 'order_access.dart';

class CreatePaymentResult {
  const CreatePaymentResult({
    required this.access,
    required this.confirmationUrl,
  });

  final OrderAccess access;
  final Uri confirmationUrl;

  factory CreatePaymentResult.fromJson(Map<String, dynamic> json) {
    return CreatePaymentResult(
      access: OrderAccess(
        orderId: json['orderId'] as String,
        accessToken: json['accessToken'] as String,
      ),
      confirmationUrl: Uri.parse(json['confirmationUrl'] as String),
    );
  }
}
