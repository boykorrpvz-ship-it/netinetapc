import 'order_access.dart';
import 'vpn_product.dart';

class CreatePaymentResult {
  const CreatePaymentResult({
    required this.access,
    required this.confirmationUrl,
  });

  final OrderAccess access;
  final Uri confirmationUrl;

  factory CreatePaymentResult.fromJson(
    Map<String, dynamic> json, {
    required VpnProduct product,
  }) {
    return CreatePaymentResult(
      access: OrderAccess(
        orderId: json['orderId'] as String,
        accessToken: json['accessToken'] as String,
        product: VpnProduct.fromApi(json['vpnType'] ?? product.apiValue),
      ),
      confirmationUrl: Uri.parse(json['confirmationUrl'] as String),
    );
  }
}
