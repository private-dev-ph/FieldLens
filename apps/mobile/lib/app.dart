import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/core/structured_log.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FieldLensApp extends StatelessWidget {
  const FieldLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldLens',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF155E75)),
        useMaterial3: true,
      ),
      home: const WorkDashboardScreen(),
    );
  }
}

class WorkDashboardScreen extends ConsumerStatefulWidget {
  const WorkDashboardScreen({super.key});

  @override
  ConsumerState<WorkDashboardScreen> createState() =>
      _WorkDashboardScreenState();
}

class _WorkDashboardScreenState extends ConsumerState<WorkDashboardScreen> {
  final Set<String> _startingWorkOrderIds = {};
  final Set<String> _openingInspectionIds = {};

  @override
  Widget build(BuildContext context) {
    final assignedWork = ref.watch(assignedWorkProvider);
    final pendingCount = ref.watch(pendingMutationCountProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('FieldLens'), centerTitle: false),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SyncStatusBanner(pendingCount: pendingCount),
            Expanded(
              child: assignedWork.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => _LoadError(
                  message: error.toString(),
                  onRetry: () => ref.invalidate(assignedWorkProvider),
                ),
                data: (workOrders) {
                  if (workOrders.isEmpty) {
                    return const _EmptyAssignments();
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: workOrders.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final workOrder = workOrders[index];
                      return _WorkOrderCard(
                        workOrder: workOrder,
                        onInspect: _openingInspectionIds.contains(workOrder.id)
                            ? null
                            : () => _openInspection(workOrder),
                        showStartButton: _isAssigned(workOrder.status),
                        isStarting: _startingWorkOrderIds.contains(
                          workOrder.id,
                        ),
                        onStart:
                            _isAssigned(workOrder.status) &&
                                !_startingWorkOrderIds.contains(workOrder.id)
                            ? () => _startWorkOrder(workOrder)
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startWorkOrder(WorkOrderSummary workOrder) async {
    if (!_startingWorkOrderIds.add(workOrder.id)) return;
    setState(() {});
    try {
      await ref
          .read(workRepositoryProvider)
          .setStatus(workOrder.id, 'in_progress');
    } catch (error, stackTrace) {
      StructuredLog.error(
        'work_order_start_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'workOrderId': workOrder.id},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start this work order.')),
        );
      }
    } finally {
      _startingWorkOrderIds.remove(workOrder.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openInspection(WorkOrderSummary workOrder) async {
    if (!_openingInspectionIds.add(workOrder.id)) return;
    setState(() {});
    try {
      final id = await ref
          .read(inspectionRepositoryProvider)
          .beginDraft(workOrder.id);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => InspectionScreen(draftId: id)),
      );
    } catch (error, stackTrace) {
      StructuredLog.error(
        'inspection_open_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this inspection.')),
        );
      }
    } finally {
      _openingInspectionIds.remove(workOrder.id);
      if (mounted) setState(() {});
    }
  }

  bool _isAssigned(String status) => _statusText(status) == 'assigned';
}

class _SyncStatusBanner extends StatelessWidget {
  const _SyncStatusBanner({required this.pendingCount});

  final AsyncValue<int> pendingCount;

  @override
  Widget build(BuildContext context) {
    final message = pendingCount.when(
      loading: () => 'Checking queued local changes…',
      error: (error, stackTrace) => 'Unable to read local sync queue',
      data: (count) => count == 0
          ? 'No pending local changes'
          : '$count ${count == 1 ? 'change' : 'changes'} queued locally',
    );

    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    'Synchronization is not configured yet',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkOrderCard extends StatelessWidget {
  const _WorkOrderCard({
    required this.workOrder,
    required this.showStartButton,
    required this.isStarting,
    this.onInspect,
    this.onStart,
  });

  final WorkOrderSummary workOrder;
  final bool showStartButton;
  final bool isStarting;
  final VoidCallback? onStart;
  final VoidCallback? onInspect;

  @override
  Widget build(BuildContext context) {
    final status = _statusText(workOrder.status);
    final statusLabel = _readableStatus(status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    workOrder.assetTag,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Chip(label: Text(statusLabel)),
              ],
            ),
            const SizedBox(height: 4),
            Text(workOrder.assetType),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.location_on_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(workOrder.siteName)),
              ],
            ),
            if (showStartButton) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: ValueKey('start-${workOrder.id}'),
                  onPressed: onStart,
                  icon: isStarting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(isStarting ? 'Starting…' : 'Start work order'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: ValueKey('inspect-${workOrder.id}'),
              onPressed: onInspect,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Open inspection'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyAssignments extends StatelessWidget {
  const _EmptyAssignments();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.assignment_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'No assigned work',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('Assigned work will appear here when it is available.'),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(
              'Could not load assigned work',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusText(String status) => status.toLowerCase();

String _readableStatus(String status) => status
    .split('_')
    .map(
      (part) =>
          part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}',
    )
    .join(' ');
